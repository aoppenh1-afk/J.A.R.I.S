/*
 * J.A.R.V.I.S. host adapter for the vendored glass-voice-orb-study renderer.
 * The upstream renderer, shaders, uniforms, pipeline, and spring state machine
 * remain unmodified. This file maps native VoiceState values into the upstream
 * channels and sizes the original desktop orb correctly inside compact native
 * preview/live-orb surfaces.
 */
(function () {
  "use strict";

  const canvas = document.querySelector("#siri-canvas");
  const params = window.SIRI_PARAMS || (window.SIRI_PARAMS = {});
  const LIQUID_GLASS_PRESET = Object.freeze({
    containerStrength: 0.9,
    containerBlack: 0.25,
    containerFade: 1,
    containerGauss: 8,
    refractAmount: -56,
    glassHeight: 18,
    curvature: 1,
    hlAmount: 0.72,
    hlHeight: 2.2,
    hlCut: 0.52,
    shadowAmount: 0.4,
    causticAmount: 1.6,
    shadowOffsetY: 0.3,
    causticOffsetY: -1,
    projectionSoftness: 4.2,
    ballWidth: 128,
    breathAmount: 0.028,
    breathSpeed: 1.65,
    margin: 20,
    dialogCloseBounce: 0.032,
    dialogWidth: 500,
    dialogHeight: 150,
    waveAmplitude: 0.22,
    waveScale: 0.9,
    waveAberration: 2.6,
    waveThickness: 3,
    waveIntensity: 2,
    waveBandFill: 30000,
    waveBandFillThickness: 0.08,
    waveSoftness: 2.5,
    waveWhiteClip: 1,
    dotGlow: 0.055,
    caretGlowSize: 90,
    caretGlowAlpha: 1,
  });
  Object.assign(params, LIQUID_GLASS_PRESET);

  function report(status, detail) {
    try {
      window.webkit?.messageHandlers?.glassOrbStatus?.postMessage({
        status,
        detail: String(detail || ""),
      });
    } catch (_) {
      // The standalone browser demo has no native message handler.
    }
  }

  function syncHostLayout() {
    const rect = canvas.getBoundingClientRect();
    const width = rect.width || window.innerWidth || 128;
    const height = rect.height || window.innerHeight || 128;

    // Keep the supplied Liquid Glass preset exact across both the settings preview
    // and the live floating window. The transparent WebGL canvas may be larger than
    // the fixed 128px sphere, preserving the native click and drag surface.
    params.ballWidth = LIQUID_GLASS_PRESET.ballWidth;
    params.margin = LIQUID_GLASS_PRESET.margin;
  }

  syncHostLayout();

  let renderer;
  let state;
  try {
    renderer = new window.SiriRenderer(canvas);
    state = new window.SiriState();
  } catch (error) {
    document.documentElement.dataset.ready = "false";
    report("error", error?.stack || error);
    console.error("Glass voice orb failed to construct", error);
    return;
  }

  let hostMode = "idle";
  let appliedMode = null;
  let appliedPressed = null;
  let energy = 0.18;
  let nativeAudio = { low: 0, mid: 0, high: 0 };
  const renderedAudio = { low: 0, mid: 0, high: 0 };
  let reducedMotion = false;
  let lastFrame = performance.now();
  let shaderElapsed = 0;
  let resizeObserver;
  const reply = document.querySelector("#siri-reply");

  function upstreamMode(mode) {
    if (mode === "dialog") return "dialog";
    if (mode === "thinking") return "thinking";
    if (mode === "listening" || mode === "speaking") return "listening";
    return "idle";
  }

  function setAudio(low, mid, high) {
    nativeAudio = {
      low: Math.max(0, Math.min(1, Number(low) || 0)),
      mid: Math.max(0, Math.min(1, Number(mid) || 0)),
      high: Math.max(0, Math.min(1, Number(high) || 0)),
    };
  }

  function audioBands() {
    const active = hostMode === "listening" || hostMode === "speaking";
    const target = active ? nativeAudio : { low: 0, mid: 0, high: 0 };

    // Audio targets arrive over a lightweight, coalesced native channel. The
    // WebGL frame loop owns all visible interpolation so motion remains fluid.
    for (const band of ["low", "mid", "high"]) {
      renderedAudio[band] += (target[band] - renderedAudio[band]) * 0.22;
      if (!active && renderedAudio[band] < 0.0005) renderedAudio[band] = 0;
    }
    return renderedAudio;
  }

  function motionScale() {
    if (reducedMotion) return 0.035;
    if (hostMode === "thinking" || hostMode === "listening" || hostMode === "speaking") return 1;
    return 0.2;
  }

  function update(payload) {
    const next = payload || {};
    hostMode = typeof next.mode === "string" ? next.mode : "idle";
    energy = Number.isFinite(next.energy) ? next.energy : energy;
    reducedMotion = Boolean(next.reducedMotion);

    const mode = upstreamMode(hostMode);
    const pressed = hostMode === "listening";
    if (mode !== appliedMode) {
      appliedMode = mode;
      state.select(mode);
      document.documentElement.dataset.mode = mode;
    }
    if (pressed !== appliedPressed) {
      appliedPressed = pressed;
      state.setPressed(pressed);
    }

    if (reply) {
      const text = String(next.assistantText || next.statusText || "").trim();
      const length = Array.from(text).length;
      reply.dataset.length = length > 420 ? "very-long" : length > 240 ? "long" : "normal";
      reply.textContent = text;
    }
  }

  window.jarvisOrb = {
    update,
    setAudio,
    status() {
      return {
        ready: document.documentElement.dataset.ready === "true",
        width: canvas.width,
        height: canvas.height,
        cssWidth: canvas.clientWidth,
        cssHeight: canvas.clientHeight,
        ballWidth: params.ballWidth,
        mode: hostMode,
        audio: nativeAudio,
        webgl2: Boolean(renderer.gl),
      };
    },
  };


  function frame(now) {
    const rawDelta = Math.min(0.05, (now - lastFrame) / 1000);
    lastFrame = now;

    shaderElapsed += rawDelta * motionScale();
    const audio = audioBands();
    const channels = state.step(rawDelta, audio);
    channels.audio = audio;
    renderer.setFrame(channels, shaderElapsed);
    renderer.render();
    requestAnimationFrame(frame);
  }

  async function boot() {
    try {
      await renderer.init();
      syncHostLayout();
      renderer.resize();

      resizeObserver = new ResizeObserver(() => {
        syncHostLayout();
        renderer.resize();
      });
      resizeObserver.observe(canvas);

      lastFrame = performance.now();
      shaderElapsed = 0;
      update({ mode: hostMode, energy, reducedMotion });
      document.documentElement.dataset.ready = "true";
      report("ready", JSON.stringify(window.jarvisOrb.status()));
      requestAnimationFrame(frame);
    } catch (error) {
      document.documentElement.dataset.ready = "false";
      report("error", error?.stack || error);
      console.error("Glass voice orb failed to start", error);
    }
  }

  boot();
})();
