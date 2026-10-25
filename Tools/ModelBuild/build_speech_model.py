#!/usr/bin/env python3
"""Builds the on-device Tamil speech model for Saptham.

Downloads AI4Bharat's IndicConformer checkpoint (MIT licence, see
Apps/Mac/Support/ThirdPartyNotices.txt), keeps only what Tamil live captions
need, and converts it to a fixed-window Core ML model:

    16 kHz mono audio, WINDOW seconds  ->  CTC log-probabilities [257, frames]
                                           (256 Tamil word pieces + blank,
                                            one frame per 40 ms)

Outputs, written to Models/ (git-ignored; the Xcode project bundles them):
    TamilSpeech.mlpackage   the network
    TamilSpeech.json        vocabulary and the numbers the app needs to use it

Build-time tools (NeMo, PyTorch, coremltools) run only here and never ship.

    python3.12 -m venv .venv && .venv/bin/pip install -r requirements.txt
    .venv/bin/python build_speech_model.py            # build
    .venv/bin/python build_speech_model.py --check N  # compare with PyTorch on N FLEURS clips
"""
import argparse, hashlib, json, logging, math, os, sys, tarfile, urllib.request
from pathlib import Path

import numpy as np
import torch, torch.nn as nn, torch.nn.functional as F
import yaml

logging.disable(logging.WARNING)

CHECKPOINTS = {
    # Tamil-specific model (126 M parameters). Chosen over the 600 M
    # multilingual model: same Tamil WER on FLEURS, five times smaller.
    "ta-large": dict(
        url="https://objectstore.e2enetworks.net/indicconformer/models/indicconformer_stt_ta_hybrid_rnnt_large.nemo",
        sha256="40a6fce3374ceb67daa2a071e92f0948c51c6a95b734d4881a3bcfe0b1bed32a"),
    "multi-600m": dict(
        url="https://objectstore.e2enetworks.net/indicconformer/models/indicconformer_stt_multi_hybrid_rnnt_600m.nemo",
        sha256="5d33cd4c21b5ec60c51e292b9d8af065b67ad1e80135266a0546ec5c60148426"),
}
LANGUAGE = "ta"
SAMPLE_RATE = 16_000
HOP = 160                 # 10 ms feature hop
SUBSAMPLING = 4           # Conformer frames are 40 ms
PIECES_PER_LANGUAGE = 256
REPO = Path(__file__).resolve().parents[2]
CACHE = Path.home() / "Library/Caches/SapthamModelBuild"


def download(name):
    spec = CHECKPOINTS[name]
    path = CACHE / Path(spec["url"]).name
    CACHE.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        print(f"downloading {spec['url']}")
        urllib.request.urlretrieve(spec["url"], path)
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != spec["sha256"]:
        sys.exit(f"{path.name}: checksum {digest} does not match the pinned {spec['sha256']}")
    unpacked = CACHE / name
    if not (unpacked / "model_config.yaml").exists():
        unpacked.mkdir(exist_ok=True)
        with tarfile.open(path) as tar:
            tar.extractall(unpacked, filter="data")
    return unpacked


class Checkpoint(nn.Module):
    """The checkpoint's Tamil path, rebuilt from its config and weights.

    NeMo provides the preprocessor and Conformer encoder. The checkpoint's
    per-language output heads come from AI4Bharat's NeMo fork, so the
    prediction network, joint and CTC heads are rebuilt here and sliced to
    the Tamil vocabulary."""

    def __init__(self, unpacked, language=LANGUAGE):
        super().__init__()
        from nemo.collections.asr.modules import AudioToMelSpectrogramPreprocessor, ConformerEncoder
        cfg = yaml.safe_load(open(unpacked / "model_config.yaml"))
        sd = torch.load(unpacked / "model_weights.ckpt", map_location="cpu", weights_only=False)
        languages = list(cfg["tokenizer"]["langs"].keys())
        self.offset = languages.index(language) * PIECES_PER_LANGUAGE
        self.vocab = cfg["joint"]["vocabulary"][self.offset:self.offset + PIECES_PER_LANGUAGE]
        self.blank = cfg["decoder"]["vocab_size"]
        strip = lambda section: {k: v for k, v in cfg[section].items() if k != "_target_"}
        self.pre = AudioToMelSpectrogramPreprocessor(**strip("preprocessor"))
        self.enc = ConformerEncoder(**strip("encoder"))
        pred = cfg["decoder"]["prednet"]["pred_hidden"]
        joint = cfg["joint"]["jointnet"]["joint_hidden"]
        self.embed = nn.Embedding(self.blank + 1, pred)
        self.lstm = nn.LSTM(pred, pred, cfg["decoder"]["prednet"]["pred_rnn_layers"], batch_first=True)
        self.j_enc = nn.Linear(cfg["encoder"]["d_model"], joint)
        self.j_pred = nn.Linear(pred, joint)
        self.j_out = nn.Linear(joint, PIECES_PER_LANGUAGE + 1)
        self.ctc = nn.Conv1d(cfg["encoder"]["d_model"], self.blank + 1, 1)
        part = lambda p: {k[len(p):]: v for k, v in sd.items() if k.startswith(p)}
        self.pre.load_state_dict(part("preprocessor."), strict=False)
        self.enc.load_state_dict(part("encoder."))
        self.embed.load_state_dict(part("decoder.prediction.embed."))
        self.lstm.load_state_dict({k.replace("lstm.", ""): v for k, v in part("decoder.prediction.dec_rnn.").items()})
        self.j_enc.load_state_dict(part("joint.enc."))
        self.j_pred.load_state_dict(part("joint.pred."))
        self.j_out.load_state_dict(part(f"joint.joint_net.2.{language}."))
        self.ctc.load_state_dict(part("ctc_decoder.decoder_layers.0."))
        self.eval()

    def text(self, ids):
        return "".join(self.vocab[i] for i in ids).replace("▁", " ").strip()

    @torch.no_grad()
    def transcribe(self, wav, rnnt=False):
        x, xl = self.pre(input_signal=wav[None], length=torch.tensor([wav.shape[0]]))
        e, _ = self.enc(audio_signal=x, length=xl)
        return self._rnnt(e) if rnnt else self._ctc(e)

    def _ctc(self, e):
        full = self.ctc(e)[0]
        ids = torch.cat([full[self.offset:self.offset + PIECES_PER_LANGUAGE], full[self.blank:]], 0).argmax(0)
        return self.text(collapse(ids.tolist(), PIECES_PER_LANGUAGE))

    def _rnnt(self, e, max_symbols=10):
        # The prediction network embeds the language-local piece index.
        f = self.j_enc(e[0].T)
        g, state = self.lstm(self.embed(torch.tensor([[self.blank]])))
        out = []
        for t in range(f.shape[0]):
            for _ in range(max_symbols):
                k = self.j_out(torch.relu(f[t] + self.j_pred(g[0, 0]))).argmax().item()
                if k == PIECES_PER_LANGUAGE:
                    break
                out.append(k)
                g, state = self.lstm(self.embed(torch.tensor([[k]])), state)
        return self.text(out)


def collapse(ids, blank):
    out, prev = [], None
    for i in ids:
        if i != prev and i != blank:
            out.append(i)
        prev = i
    return out


class Featurizer(nn.Module):
    """NeMo's AudioToMelSpectrogramPreprocessor (inference mode) with static
    shapes: pre-emphasis 0.97, centred 512-point STFT (400-sample symmetric
    Hann window, 160 hop) as a convolution, power spectrum, 80 mel bands,
    log(x + 2^-24), per-band normalisation over the window."""

    def __init__(self, filterbank, n_fft=512, win=400, preemph=0.97):
        super().__init__()
        self.n_fft, self.preemph = n_fft, preemph
        w = torch.hann_window(win, periodic=False)
        left = (n_fft - win) // 2
        w = F.pad(w, (left, n_fft - win - left))
        k = torch.arange(n_fft // 2 + 1).float()[:, None]
        n = torch.arange(n_fft).float()[None]
        angle = 2 * math.pi * k * n / n_fft
        self.register_buffer("cos_kernel", (torch.cos(angle) * w)[:, None, :])
        self.register_buffer("sin_kernel", (-torch.sin(angle) * w)[:, None, :])
        self.register_buffer("filterbank", filterbank[0].clone())

    def forward(self, audio):
        x = torch.cat([audio[:, :1], audio[:, 1:] - self.preemph * audio[:, :-1]], 1)
        x = F.pad(x[:, None], (self.n_fft // 2, self.n_fft // 2))
        re = F.conv1d(x, self.cos_kernel, stride=HOP)
        im = F.conv1d(x, self.sin_kernel, stride=HOP)
        # NeMo counts N // hop valid frames and masks the extra frame a
        # centred STFT produces; drop it.
        mel = torch.log(torch.matmul(self.filterbank, re * re + im * im) + 2 ** -24)[:, :, :-1]
        mean = mel.mean(2, keepdim=True)
        std = torch.sqrt(((mel - mean) ** 2).sum(2, keepdim=True) / (mel.shape[2] - 1)) + 1e-5
        return (mel - mean) / std


class FixedRelPositionalEncoding(nn.Module):
    """NeMo's RelPositionalEncoding with its slice fixed for one input length
    (the length-dependent slicing does not convert to Core ML)."""

    def __init__(self, pos_enc, frames):
        super().__init__()
        self.xscale = pos_enc.xscale
        centre = pos_enc.pe.size(1) // 2 + 1
        self.register_buffer("pos_emb", pos_enc.pe[:, centre - frames:centre + frames - 1].clone())

    def forward(self, x, cache_len=0):
        if self.xscale:
            x = x * self.xscale
        return x, self.pos_emb


class WindowNetwork(nn.Module):
    """audio [1, samples] -> Tamil CTC log-probabilities [257, frames]."""

    def __init__(self, ckpt, samples):
        super().__init__()
        self.feat = Featurizer(ckpt.pre.featurizer.fb)
        self.enc = ckpt.enc
        self.frames = encoder_frames(samples)
        self.enc.pos_enc = FixedRelPositionalEncoding(self.enc.pos_enc, self.frames)
        o, b = ckpt.offset, ckpt.blank
        self.register_buffer("w", torch.cat([ckpt.ctc.weight[o:o + PIECES_PER_LANGUAGE], ckpt.ctc.weight[b:]], 0))
        self.register_buffer("b", torch.cat([ckpt.ctc.bias[o:o + PIECES_PER_LANGUAGE], ckpt.ctc.bias[b:]], 0))

    def forward(self, audio):
        f = self.feat(audio)
        e, _ = self.enc(audio_signal=f, length=torch.full((1,), f.shape[2], dtype=torch.int64))
        return F.conv1d(e, self.w, self.b)[0].log_softmax(0)


def encoder_frames(samples):
    frames = samples // HOP
    for _ in range(int(math.log2(SUBSAMPLING))):   # stride-2, kernel-3, padding-1 convolutions
        frames = (frames + 2 - 3) // 2 + 1
    return frames


def build(args):
    import coremltools as ct
    ckpt = Checkpoint(download(args.checkpoint))
    samples = args.window * SAMPLE_RATE
    net = WindowNetwork(ckpt, samples).eval()
    example = torch.randn(1, samples) * 0.05
    with torch.no_grad():
        traced = torch.jit.trace(net, (example,), check_trace=False)
    model = ct.convert(
        traced,
        inputs=[ct.TensorType("audio", shape=(1, samples))],
        outputs=[ct.TensorType("ctc_logprobs")],
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=ct.precision.FLOAT16)
    model.short_description = "Tamil speech recognition (CTC), fixed window"
    model.author = "AI4Bharat IndicConformer, MIT licence; converted for Saptham"
    model.license = "MIT"
    out = REPO / "Models"
    out.mkdir(exist_ok=True)
    model.save(out / "TamilSpeech.mlpackage")
    meta = dict(
        language=LANGUAGE,
        sampleRate=SAMPLE_RATE,
        windowSamples=samples,
        frameSamples=HOP * SUBSAMPLING,
        frames=net.frames,
        blank=PIECES_PER_LANGUAGE,
        wordStartMarker="▁",
        vocabulary=ckpt.vocab,
        source=CHECKPOINTS[args.checkpoint]["url"],
        sourceSHA256=CHECKPOINTS[args.checkpoint]["sha256"],
    )
    (out / "TamilSpeech.json").write_text(json.dumps(meta, ensure_ascii=False, indent=1))
    print(f"wrote {out}/TamilSpeech.mlpackage and TamilSpeech.json ({net.frames} frames per {args.window} s)")


def check(args):
    """How often the Core ML model's words differ from the PyTorch
    checkpoint's on the same window, over the first N FLEURS Tamil test clips.
    Measures the conversion, not the model's accuracy."""
    import coremltools as ct, csv, jiwer, soundfile as sf, unicodedata
    fleurs = CACHE / "fleurs"
    if not (fleurs / "test.tsv").exists():
        sys.exit(f"put FLEURS ta_in test.tsv and test/ in {fleurs} (CC-BY-4.0, evaluation only, never shipped)")
    ckpt = Checkpoint(download(args.checkpoint))
    meta = json.loads((REPO / "Models/TamilSpeech.json").read_text())
    model = ct.models.MLModel(str(REPO / "Models/TamilSpeech.mlpackage"), compute_units=ct.ComputeUnit.CPU_AND_GPU)
    norm = lambda s: " ".join("".join(c for c in s if not unicodedata.category(c).startswith("P")).split())
    rows = list(csv.reader(open(fleurs / "test.tsv"), delimiter="\t", quoting=csv.QUOTE_NONE))[:args.check]
    torch_h, coreml_h = [], []
    n = meta["windowSamples"]
    for r in rows:
        wav, _ = sf.read(fleurs / "test" / r[1], dtype="float32")
        padded = np.pad(wav[:n], (0, max(0, n - len(wav))))
        torch_h.append(norm(ckpt.transcribe(torch.from_numpy(padded))))
        ids = model.predict({"audio": padded[None]})["ctc_logprobs"].argmax(0)
        coreml_h.append(norm(ckpt.text(collapse(ids.tolist(), meta["blank"]))))
    agree = jiwer.wer(torch_h, coreml_h)
    print(f"Core ML vs PyTorch word disagreement on {len(rows)} clips (first {args.window} s): {agree:.3f}")
    return agree


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--checkpoint", choices=CHECKPOINTS, default="ta-large")
    p.add_argument("--window", type=int, default=8, help="seconds of audio per model call")
    p.add_argument("--check", type=int, metavar="N", help="verify an existing build on N clips")
    a = p.parse_args()
    check(a) if a.check else build(a)
