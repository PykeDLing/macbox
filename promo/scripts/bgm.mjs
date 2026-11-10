// MacBox 宣传片的配乐。整首曲子由这个脚本逐个采样算出来：没有采样素材，没有外部依赖，
// 随机数用固定种子，所以每次生成的文件完全一样。
//
//   node scripts/bgm.mjs            → public/bgm.wav（48 kHz 立体声 16 位）
//
// 风格：安静的氛围电子打底（合成器铺底 + 中音区的 FM 键盘动机），副歌进 trap 的鼓组——
// 半拍感的拍手、808 滑音低音、带滚奏的踩镲。A 小调 / C 大调，F – Am – C – G 四小节一轮。
//
// 节拍跟着画面走：一小节 = 47 帧（约 153 BPM），第 0 小节从第 20 帧开始，
// 这样 promo/src/theme.ts 里每个镜头淡入完的那一帧都落在小节线上（见下面的 SECTIONS）。
// 镜头长度改了，这里的编曲要跟着重排。

import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const SR = 48000;
const FPS = 30;
const FRAMES = 1654;
const BAR = 47 / FPS;
const STEP = BAR / 16;
const T0 = 20 / FPS;
const N = Math.round((FRAMES / FPS) * SR);
const TAU = Math.PI * 2;

/** 第 bar 小节第 step 个十六分音符的时间（秒） */
const at = (bar, step = 0) => T0 + bar * BAR + step * STEP;
const frameOf = (seconds) => Math.round(seconds * FPS);

// 小节 → 画面。只用来在生成时打印核对
const SECTIONS = [
  [0, '问题：零零散散的音'],
  [4.5, '主意：动机出现'],
  [8, '添加：鼓进来'],
  [12, '原生：滑音合成器把动机连起来唱'],
  [16, '报告：低音区的闷音脉冲'],
  [20, '保护：更重的 808'],
  [24, '删除：鼓停，滤波往下扫，四个对勾'],
  [28, '数字：全部乐器'],
  [31, '片尾：落在 C 上'],
];

// —— 基础 ——

let seed = 0x4d426f78; // "MBox"
function rand() {
  seed = (seed + 0x6d2b79f5) | 0;
  let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}
const noise = () => rand() * 2 - 1;

const SEMITONE = { C: 0, D: 2, E: 4, F: 5, G: 7, A: 9, B: 11 };
function hz(name, octaves = 0) {
  const m = /^([A-G])([#b]?)(\d)$/.exec(name);
  const semis = SEMITONE[m[1]] + (m[2] === '#' ? 1 : m[2] === 'b' ? -1 : 0) + (Number(m[3]) + 1) * 12;
  return 440 * 2 ** ((semis - 69) / 12 + octaves);
}

const bus = () => ({ l: new Float32Array(N), r: new Float32Array(N) });
const drums = bus();
const hats = bus();
const snare = bus();
const bass = bus();
const pad = bus();
const lead = bus();
const glideBus = bus();
const fx = bus();

/** 往 b 里加一个音：fn(这个音开始后的秒数) 给出单声道采样，pan 是 -1（左）到 1（右） */
function put(b, t, dur, pan, gain, fn) {
  const start = Math.round(t * SR);
  const len = Math.round(dur * SR);
  const gl = gain * Math.cos(((pan + 1) * Math.PI) / 4);
  const gr = gain * Math.sin(((pan + 1) * Math.PI) / 4);
  const fade = 0.005 * SR;
  for (let n = 0; n < len; n++) {
    const i = start + n;
    if (i >= N) break;
    // 每个音都要算，哪怕落在开头之前，这样随机数的顺序不变
    const s = fn(n / SR) * Math.min(1, (len - n) / fade);
    if (i < 0) continue;
    b.l[i] += s * gl;
    b.r[i] += s * gr;
  }
}

/** 状态变量滤波器（TPT），一次算出低通、带通、高通 */
class Svf {
  a = 0;
  b = 0;
  lp = 0;
  bp = 0;
  hp = 0;
  freq = -1;
  set(freq, q = 0.707) {
    if (freq === this.freq) return this;
    this.freq = freq;
    const g = Math.tan((Math.PI * Math.min(freq, SR * 0.45)) / SR);
    this.k = 1 / q;
    this.a1 = 1 / (1 + g * (g + this.k));
    this.a2 = g * this.a1;
    this.a3 = g * this.a2;
    return this;
  }
  run(x) {
    const v3 = x - this.b;
    const v1 = this.a1 * this.a + this.a2 * v3;
    const v2 = this.b + this.a2 * this.a + this.a3 * v3;
    this.a = 2 * v1 - this.a;
    this.b = 2 * v2 - this.b;
    this.lp = v2;
    this.bp = v1;
    this.hp = x - this.k * v1 - v2;
    return this;
  }
}

// 底鼓一响，铺底和旋律让一下（侧链）
const duck = new Float32Array(N).fill(1);
function duckAt(t, depth) {
  const start = Math.round(t * SR);
  const len = Math.round(0.5 * SR);
  for (let n = 0; n < len; n++) {
    const i = start + n;
    if (i < 0) continue;
    if (i >= N) break;
    const tt = n / SR;
    const v = 1 - depth * Math.min(1, tt / 0.004) * Math.exp(-tt / 0.13);
    if (v < duck[i]) duck[i] = v;
  }
}

// —— 乐器 ——

function kick(t, gain = 1, depth = 0.55) {
  let ph = 0;
  put(drums, t, 0.32, 0, gain, (tt) => {
    ph += (TAU * (47 + 160 * Math.exp(-tt / 0.02))) / SR;
    const click = tt < 0.003 ? noise() * 0.3 * (1 - tt / 0.003) : 0;
    return Math.tanh(1.7 * (Math.sin(ph) * Math.exp(-tt / 0.085) + click));
  });
  if (depth > 0) duckAt(t, depth);
}

/** 808 低音：正弦加一点过载，好让小喇叭也听得到。slide = { ratio, at }，at 是第几个十六分音符开始滑 */
function sub(t, steps, note, gain = 1, slide = null) {
  const dur = steps * STEP;
  const f0 = hz(note);
  const slideAt = slide ? slide.at * STEP : Infinity;
  let ph = 0;
  put(bass, t, dur, 0, gain, (tt) => {
    let f = f0;
    if (tt > slideAt) {
      const p = Math.min(1, (tt - slideAt) / 0.1);
      f = f0 * slide.ratio ** (p * p * (3 - 2 * p));
    }
    ph += (TAU * f * (1 + 0.8 * Math.exp(-tt / 0.012))) / SR;
    const env = Math.min(1, tt / 0.004) * Math.exp(-tt / (dur * 0.7 + 0.2));
    // 高八度再叠一层：四五十赫兹的基音笔记本喇叭放不出来，靠泛音才听得到
    return 0.72 * (Math.tanh(2.6 * Math.sin(ph) * env) / Math.tanh(2.6)) + 0.3 * Math.sin(2 * ph) * env;
  });
}

/** 没有过载的柔和低音，鼓进来之前用 */
function softSub(t, steps, note, gain) {
  const dur = steps * STEP;
  const f = hz(note);
  put(bass, t, dur, 0, gain, (tt) => {
    const env = Math.sin(Math.min(1, tt / 0.12) * (Math.PI / 2)) * Math.min(1, (dur - tt) / 0.25);
    return (Math.sin(TAU * f * tt) + 0.25 * Math.sin(TAU * f * 2 * tt)) * env;
  });
}

function clap(t, gain = 1) {
  for (const pan of [-0.45, 0.45]) {
    const band = new Svf().set(1650, 1.3);
    put(snare, t, 0.42, pan, gain, (tt) => {
      let env = 0;
      for (const d of [0, 0.011, 0.022]) {
        if (tt >= d) env = Math.max(env, Math.exp(-(tt - d) / 0.006));
      }
      if (tt >= 0.031) env = Math.max(env, 0.75 * Math.exp(-(tt - 0.031) / 0.07));
      return band.run(noise()).bp * env * 2.4;
    });
  }
  // 一点点军鼓的鼓腔
  put(snare, t, 0.12, 0, gain * 0.35, (tt) => Math.sin(TAU * 185 * tt) * Math.exp(-tt / 0.03));
}

function hat(t, gain = 1, decay = 0.02, pan = 0.2) {
  const high = new Svf().set(8200, 0.9);
  put(hats, t, decay * 6, pan, gain, (tt) => {
    return high.run(noise()).hp * Math.exp(-tt / decay) * Math.min(1, tt / 0.0006);
  });
}

/** FM 键盘 / 拨弦。bell 越大越像金属铃，warm 是垫在低八度的一层正弦 */
function pluck(b, t, note, gain = 1, opts = {}) {
  const { pan = 0, decay = 0.34, bright = 2, bell = 0.2, warm = 0, cents = 0, octaves = 0 } = opts;
  const f = hz(note, octaves) * 2 ** (cents / 1200);
  put(b, t, decay * 5.5, pan, gain, (tt) => {
    const index = bright * Math.exp(-tt / 0.075) + 0.22;
    const body = Math.sin(TAU * f * tt + index * Math.sin(TAU * f * 2 * tt));
    const ring =
      Math.sin(TAU * f * 2 * tt + 1.1 * Math.exp(-tt / 0.16) * Math.sin(TAU * f * 7 * tt)) *
      Math.exp(-tt / 0.2);
    const low = warm * Math.sin(TAU * f * 0.5 * tt);
    return (body * 0.8 + ring * bell + low) * Math.min(1, tt / 0.003) * Math.exp(-tt / decay);
  });
}

/** 带滑音和颤音的单声部主旋律。notes: [开始的十六分音符, 长度, 音名] */
function glide(t, notes, gain = 1, octaves = 0) {
  const end = Math.max(...notes.map(([s, len]) => s + len)) * STEP;
  let f = hz(notes[0][2], octaves);
  let ph = 0;
  let k = 0;
  const coef = Math.exp(-1 / (0.045 * SR));
  put(glideBus, t, end + 0.25, -0.1, gain, (tt) => {
    while (k + 1 < notes.length && tt >= notes[k + 1][0] * STEP) k++;
    const target = hz(notes[k][2], octaves);
    f = target + (f - target) * coef;
    const vib = 1 + 0.006 * Math.min(1, tt / 0.5) * Math.sin(TAU * 5.3 * tt);
    ph += (TAU * f * vib) / SR;
    const env = Math.min(1, tt / 0.05) * Math.min(1, Math.max(0, (end + 0.25 - tt) / 0.25));
    return (Math.sin(ph) + 0.22 * Math.sin(2 * ph) + 0.07 * Math.sin(3 * ph)) * env;
  });
}

/** 三个微微失谐的锯齿波叠成的铺底音，之后整条总线再过低通 */
function padNote(t, dur, note, gain, attack) {
  const f = hz(note);
  const release = 0.7;
  [-11, 0, 11].forEach((cents, v) => {
    const dt = (f * 2 ** (cents / 1200)) / SR;
    let ph = rand();
    put(pad, t, dur + release, [-0.75, 0, 0.75][v], gain, (tt) => {
      ph += dt;
      if (ph >= 1) ph -= 1;
      let s = 2 * ph - 1;
      // polyBLEP：把锯齿的跳变磨圆，免得有混叠
      if (ph < dt) {
        const x = ph / dt;
        s -= x + x - x * x - 1;
      } else if (ph > 1 - dt) {
        const x = (ph - 1) / dt;
        s -= x * x + x + x + 1;
      }
      const a = tt < attack ? Math.sin((tt / attack) * (Math.PI / 2)) ** 2 : 1;
      const r = tt > dur ? Math.cos(Math.min(1, (tt - dur) / release) * (Math.PI / 2)) ** 2 : 1;
      return s * a * r;
    });
  });
}
const padChord = (t, dur, notes, gain = 1, attack = 0.15) =>
  notes.forEach((note) => padNote(t, dur, note, gain, attack));

/** 噪声扫频：up 往上扫（蓄势），否则往下扫（收走） */
function sweep(t, dur, gain, up) {
  for (const pan of [-0.6, 0.6]) {
    const band = new Svf();
    put(fx, t, dur, pan, gain, (tt) => {
      const p = tt / dur;
      band.set(up ? 350 * 22 ** p : 7000 * 22 ** -p, 1.6);
      return band.run(noise()).bp * (up ? p * p : (1 - p) ** 1.4 * Math.min(1, tt / 0.05));
    });
  }
}

/** 低沉的一声落地，加一小团噪声 */
function impact(t, gain = 1) {
  let ph = 0;
  put(fx, t, 1.6, 0, gain, (tt) => {
    ph += (TAU * (36 + 70 * Math.exp(-tt / 0.06))) / SR;
    return Math.sin(ph) * Math.exp(-tt / 0.4);
  });
  for (const pan of [-0.7, 0.7]) {
    const low = new Svf().set(2400, 0.7);
    put(fx, t, 1.2, pan, gain * 0.5, (tt) => low.run(noise()).lp * Math.exp(-tt / 0.22));
  }
}

// —— 和声与型 ——

const CHORDS = {
  F: { pad: ['F3', 'A3', 'C4', 'E4'], root: 'F1', pulse: ['F3', 'C4'] },
  Am: { pad: ['A3', 'C4', 'E4', 'G4'], root: 'A1', pulse: ['A3', 'E4'] },
  C: { pad: ['G3', 'B3', 'D4', 'E4'], root: 'C2', pulse: ['G3', 'C4'] },
  G: { pad: ['G3', 'B3', 'D4', 'A4'], root: 'G1', pulse: ['G3', 'D4'] },
};
const LOOP = ['F', 'Am', 'C', 'G'];

// 动机：留在中音区（D4 – C5），一小节只有两三个音，落在第 0、6、12 个十六分音符上，
// 音之间留空。音色是偏闷、偏暖的键盘，不带金属铃的泛音
const MOTIF = {
  F: [[0, 'A4'], [6, 'C5'], [12, 'A4']],
  Am: [[0, 'G4'], [10, 'E4']],
  C: [[0, 'G4'], [6, 'B4'], [12, 'G4']],
  G: [[0, 'A4'], [10, 'D4']],
};
const KEYS = { decay: 0.62, bright: 1.15, bell: 0, warm: 0.3 };
function motifBar(bar, chord, gain = 1, octaves = 0) {
  MOTIF[chord].forEach(([step, note], i) => {
    pluck(lead, at(bar, step), note, gain * (i === 0 ? 1 : 0.85), {
      ...KEYS,
      pan: i % 2 ? 0.2 : -0.2,
      octaves,
    });
  });
}

// 滑音合成器唱的就是动机那几个音，只是连起来、带滑音
const LINE = Object.fromEntries(
  Object.entries(MOTIF).map(([chord, notes]) => [
    chord,
    notes.map(([step, note], i) => [step, (notes[i + 1]?.[0] ?? 16) - step, note]),
  ]),
);
function lineOver(bar, chords, gain, octaves = 0) {
  const notes = chords.flatMap((chord, i) =>
    LINE[chord].map(([step, len, note]) => [i * 16 + step, len, note]),
  );
  glide(at(bar), notes, gain, octaves);
}

// 808：[第几个十六分音符, 长度, 力度, 滑音]
const UP = (step) => ({ ratio: 2, at: step });
const SUB_A = [
  [[0, 7], [10, 6]],
  [[0, 6], [6, 3, 0.7], [10, 6]],
  [[0, 7], [10, 4], [14, 2, 0.8]],
  [[0, 7], [7, 3, 0.7], [10, 6, 1, UP(3.5)]],
];
const SUB_B = [
  [[0, 6], [6, 2, 0.8], [10, 3], [13, 3, 0.9, UP(1)]],
  [[0, 7], [10, 6]],
  [[0, 6], [6, 2, 0.8], [10, 4], [14, 2, 0.9]],
  [[0, 7], [7, 3, 0.7], [10, 6, 1, UP(3)]],
];

function hatBar(bar, p, level, gain = 1) {
  const hits = new Map();
  for (let s = 0; s < 16; s += 2) hits.set(s, [s % 4 === 0 ? 1 : 0.6, 0.02]);
  const roll = (from, to, every, g0, g1) => {
    for (const s of [...hits.keys()]) if (s >= from && s < to) hits.delete(s);
    const count = Math.round((to - from) / every);
    for (let i = 0; i < count; i++) {
      hits.set(from + i * every, [g0 + ((g1 - g0) * i) / (count - 1), 0.013]);
    }
  };
  if (level >= 1) {
    if (p === 1) roll(12, 14, 0.5, 0.45, 0.9); // 三十二分
    if (p === 3) roll(12, 16, 0.5, 0.35, 1);
  }
  if (level >= 2) {
    if (p === 0) roll(4, 6, 2 / 3, 0.9, 0.5); // 三连音
    if (p === 2) {
      roll(6, 8, 0.5, 0.5, 0.9);
      roll(12, 14, 2 / 3, 0.9, 0.5);
    }
  }
  for (const [s, [v, decay]] of hits) hat(at(bar, s), gain * v * (0.9 + 0.2 * rand()), decay);
  if (level >= 2 && p % 2 === 0) hat(at(bar, 14), gain * 0.6, 0.085, -0.3); // 开镲
}

function drumBar(bar, p, chord, { subs = SUB_A, hats = 1 } = {}) {
  for (const [step, len, gain = 1, slide] of subs[p]) {
    sub(at(bar, step), len, CHORDS[chord].root, gain, slide);
    kick(at(bar, step), step === 0 ? 1 : step === 10 ? 0.9 : 0.6);
  }
  clap(at(bar, 8));
  hatBar(bar, p, hats);
}

/** 鼓进来之前的蓄势：拍手越来越密，最后一个十六分音符留空 */
function build(bar) {
  sweep(at(bar), BAR - STEP * 0.5, 0.5, true);
  [0, 4, 8, 10, 12, 13, 14].forEach((step, i) => clap(at(bar, step), 0.22 + i * 0.07));
  for (let s = 0; s < 14; s += 2) hat(at(bar, s), 0.6);
}

/** 「报告」里一条条记录的感觉：低音区的闷音，根音和五度来回，不往高处走 */
function pulse(bar, chord, gain) {
  const [root, fifth] = CHORDS[chord].pulse;
  [0, 3, 6, 8, 11, 14].forEach((step, i) => {
    pluck(lead, at(bar, step), i % 3 === 2 ? fifth : root, gain * (i % 3 === 0 ? 1 : 0.75), {
      pan: i % 2 ? 0.45 : -0.45,
      decay: 0.1,
      bright: 0.9,
      bell: 0,
    });
  });
}

// —— 编曲 ——

// 问题（0 – 4.5 小节）：没有鼓，悬着的 Asus2，零零散散、音高有点飘的音像留在系统里的东西，越来越多
const introEnd = at(4, 8);
padChord(0, introEnd, ['A2', 'E3', 'A3', 'B3', 'E4'], 1, 1.4);
put(bass, 0, introEnd + 0.3, 0, 0.16, (tt) => {
  return (Math.sin(TAU * 55 * tt) + 0.5 * Math.sin(TAU * 110 * tt)) * Math.min(1, tt / 1.5) * Math.min(1, (introEnd + 0.3 - tt) / 0.3);
});
const strays = ['A3', 'C4', 'E4', 'B3', 'F4', 'D4', 'E3'];
for (let bar = 0; bar < 5; bar++) {
  kick(at(bar), 0.42, 0.2);
  for (let eighth = 0; eighth < 8; eighth++) {
    const progress = (bar * 8 + eighth) / 36;
    if (bar === 4 && eighth >= 4) break;
    if (bar === 0 && eighth === 0) continue;
    if (rand() > 0.22 + 0.4 * progress) continue;
    pluck(lead, at(bar, eighth * 2), strays[Math.floor(rand() * strays.length)], 0.5 + 0.3 * rand(), {
      pan: (rand() * 2 - 1) * 0.85,
      decay: 0.2,
      bright: 1.1,
      bell: 0.12,
      cents: (rand() * 2 - 1) * 14,
    });
  }
}

// 主意（4.5 – 8）：落地一声，音都归到调上，动机第一次出现；最后一小节蓄势
impact(introEnd, 0.55);
padChord(introEnd, BAR / 2, CHORDS.Am.pad, 1, 0.25);
pluck(lead, at(4, 8), 'E4', 0.8, KEYS);
pluck(lead, at(4, 12), 'G4', 0.85, KEYS);
['F', 'Am', 'G'].forEach((chord, i) => {
  const bar = 5 + i;
  padChord(at(bar), BAR, CHORDS[chord].pad, 1, 0.2);
  softSub(at(bar), bar === 7 ? 15 : 16, CHORDS[chord].root, 0.5);
  motifBar(bar, chord, 0.85);
});
for (let s = 0; s < 16; s += 2) hat(at(6, s), s % 4 === 0 ? 0.55 : 0.35);
build(7);

// 添加、原生、报告、保护（8 – 24）：鼓组进来，四小节一轮
for (let bar = 8; bar < 24; bar++) {
  const p = (bar - 8) % 4;
  const chord = LOOP[p];
  const section = Math.floor((bar - 8) / 4); // 0 添加，1 原生，2 报告，3 保护
  padChord(at(bar), BAR, CHORDS[chord].pad, 1, 0.12);
  drumBar(bar, p, chord, {
    subs: section === 3 ? SUB_B : SUB_A,
    hats: section === 1 || section === 2 ? 2 : 1,
  });
  if (section !== 2 || p >= 2) motifBar(bar, chord, section === 2 ? 0.8 : 1);
  if (section === 2) pulse(bar, chord, 0.7);
}
impact(at(8), 0.7);
lineOver(12, LOOP, 1);
lineOver(20, LOOP, 0.9, -1);

// 删除（24 – 28）：点下「删除应用」后鼓停，滤波跟着盒子一起往下扫进废纸篓；
// 安静下来以后四个对勾各配一个往上走的铃音；最后一小节重新蓄势
padChord(at(24), BAR, CHORDS.F.pad, 1, 0.12);
drumBar(24, 0, 'F');
motifBar(24, 'F');
padChord(at(25), BAR, CHORDS.Am.pad, 1, 0.12);
kick(at(25), 1);
sub(at(25), 15, 'A1', 1, { ratio: 0.5, at: 4 });
sweep(at(25), BAR, 0.55, false);
pluck(lead, at(25), 'G4', 0.85, KEYS);
padChord(at(26), BAR, CHORDS.C.pad, 1, 0.5);
softSub(at(26), 16, 'C2', 0.45);
// 对勾出现在第 1262、1272、1282、1292 帧，隔三个十六分音符一个，正好贴得上
['E4', 'G4', 'C5', 'E5'].forEach((note, i) => {
  pluck(lead, at(26, 7 + i * 3), note, 0.85, { ...KEYS, bell: 0.1, pan: -0.3 + i * 0.2 });
});
padChord(at(27), BAR, CHORDS.G.pad, 1, 0.2);
softSub(at(27), 15, 'G1', 0.5);
build(27);

// 数字（28 – 31）：全部乐器，F – Am – G，往 C 上走
['F', 'Am', 'G'].forEach((chord, i) => {
  const bar = 28 + i;
  const p = i === 2 ? 3 : i;
  padChord(at(bar), BAR, CHORDS[chord].pad, 1, 0.12);
  drumBar(bar, p, chord, { hats: 2 });
  motifBar(bar, chord, 1);
  motifBar(bar, chord, 0.45, -1);
});
impact(at(28), 0.6);
lineOver(28, ['F', 'Am', 'G'], 1);

// 片尾（31 起）：落在 C 上，鼓只留第一下，键盘把 C 和弦慢慢走完
const endDur = N / SR - at(31);
padChord(at(31), endDur, ['C3', 'G3', 'B3', 'D4', 'E4'], 1, 0.1);
kick(at(31), 1);
sub(at(31), 20, 'C2', 0.95);
impact(at(31), 0.8);
hat(at(31), 0.5, 0.35, 0); // 一声很轻的镲
[[0, 'E4'], [6, 'G4'], [12, 'C5']].forEach(([step, note]) => pluck(lead, at(31, step), note, 0.95, KEYS));
// 第 32 小节的第 4 个十六分音符是标语出现的那一帧
pluck(lead, at(32, 4), 'G4', 0.85, { ...KEYS, pan: -0.2 });
pluck(lead, at(32, 4), 'C5', 0.7, { ...KEYS, pan: 0.2 });
pluck(lead, at(32, 12), 'E4', 0.75, KEYS);
pluck(lead, at(33, 0), 'C4', 0.8, { ...KEYS, decay: 0.8 });
pluck(lead, at(33, 0), 'G4', 0.55, { ...KEYS, decay: 0.8, pan: 0.3 });

// —— 效果与合成 ——

// 铺底的低通：闷着开头，鼓进来时打开，「删除」时扫下去
const CUTOFF = [
  [-1, 320],
  [0, 380],
  [4.5, 760],
  [7, 1500],
  [8, 2400],
  [16, 2400],
  [16.5, 1700],
  [20, 1700],
  [20.5, 1250],
  [24, 1250],
  [25, 1500],
  [26, 260],
  [26.5, 420],
  [28, 2500],
  [31, 2700],
  [35, 650],
];
function cutoffAt(t) {
  const bar = (t - T0) / BAR;
  let i = 0;
  while (i + 2 < CUTOFF.length && bar >= CUTOFF[i + 1][0]) i++;
  const [b0, f0] = CUTOFF[i];
  const [b1, f1] = CUTOFF[i + 1];
  const p = Math.min(1, Math.max(0, (bar - b0) / (b1 - b0)));
  return f0 * (f1 / f0) ** p;
}
for (const ch of [pad.l, pad.r]) {
  const one = new Svf();
  const two = new Svf();
  for (let i = 0; i < N; i++) {
    if (i % 64 === 0) {
      const f = cutoffAt(i / SR);
      one.set(f, 0.6);
      two.set(f, 0.9);
    }
    ch[i] = two.run(one.run(ch[i]).lp).lp * duck[i];
  }
}
for (let i = 0; i < N; i++) {
  const g = 1 - (1 - duck[i]) * 0.35;
  lead.l[i] *= g;
  lead.r[i] *= g;
  glideBus.l[i] *= g;
  glideBus.r[i] *= g;
}

/** 左右来回弹的延时，间隔三个十六分音符 */
function pingPong(src, feedback, wet) {
  const len = Math.round(3 * STEP * SR);
  const bl = new Float32Array(len);
  const br = new Float32Array(len);
  const out = bus();
  let lpL = 0;
  let lpR = 0;
  for (let i = 0, k = 0; i < N; i++, k = (k + 1) % len) {
    const dl = bl[k];
    const dr = br[k];
    lpL += (dl - lpL) * 0.35;
    lpR += (dr - lpR) * 0.35;
    bl[k] = (src.l[i] + src.r[i]) * 0.6 + lpR * feedback;
    br[k] = lpL * feedback;
    out.l[i] = dl * wet;
    out.r[i] = dr * wet;
  }
  return out;
}

/** Freeverb 式的混响：八个带阻尼的梳状滤波器并联，后面串四个全通 */
function reverb(src, room, damp) {
  const scale = SR / 44100;
  const combs = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617];
  const passes = [556, 441, 341, 225];
  const out = bus();
  [out.l, out.r].forEach((dst, ch) => {
    const cb = combs.map((n) => new Float32Array(Math.round((n + ch * 23) * scale)));
    const ci = cb.map(() => 0);
    const cs = cb.map(() => 0);
    const ab = passes.map((n) => new Float32Array(Math.round((n + ch * 23) * scale)));
    const ai = ab.map(() => 0);
    for (let i = 0; i < N; i++) {
      const x = (src.l[i] + src.r[i]) * 0.015;
      let acc = 0;
      for (let c = 0; c < cb.length; c++) {
        const buf = cb[c];
        const y = buf[ci[c]];
        cs[c] = y * (1 - damp) + cs[c] * damp;
        buf[ci[c]] = x + cs[c] * room;
        if (++ci[c] === buf.length) ci[c] = 0;
        acc += y;
      }
      for (let a = 0; a < ab.length; a++) {
        const buf = ab[a];
        const b = buf[ai[a]];
        buf[ai[a]] = acc + b * 0.5;
        if (++ai[a] === buf.length) ai[a] = 0;
        acc = b - acc;
      }
      dst[i] = acc;
    }
  });
  return out;
}

const echo = pingPong(lead, 0.26, 0.2);

// 各条总线的音量，以及送多少去混响
const MIX = [
  ['底鼓', drums, 0.75, 0],
  ['踩镲', hats, 0.16, 0.15],
  ['拍手', snare, 0.3, 0.5],
  ['808', bass, 0.42, 0],
  ['铺底', pad, 0.055, 0.5],
  ['动机', lead, 0.37, 0.6],
  ['动机回声', echo, 0.37, 0.5],
  ['滑音旋律', glideBus, 0.17, 0.9],
  ['效果', fx, 0.5, 0.6],
];

const send = bus();
const mix = bus();
for (const [, b, gain, toReverb] of MIX) {
  for (let i = 0; i < N; i++) {
    mix.l[i] += b.l[i] * gain;
    mix.r[i] += b.r[i] * gain;
    send.l[i] += b.l[i] * gain * toReverb;
    send.r[i] += b.r[i] * gain * toReverb;
  }
}
const wet = reverb(send, 0.86, 0.32);
const WET = 0.9;

// 母带：切掉次声，软限幅，头尾淡入淡出。峰值归到 -4.5 dBFS，整首约 -16 LUFS，
// 网页上当背景音乐不会突然很响
const fadeIn = 0.25 * SR;
const fadeOut = (54 / FPS) * SR;
let peak = 0;
for (const [dry, rev] of [
  [mix.l, wet.l],
  [mix.r, wet.r],
]) {
  const rumble = new Svf().set(32, 0.707);
  for (let i = 0; i < N; i++) {
    let s = rumble.run(dry[i] + rev[i] * WET).hp;
    s = Math.tanh(s);
    s *= Math.min(1, i / fadeIn) * Math.sin(Math.min(1, (N - i) / fadeOut) * (Math.PI / 2)) ** 2;
    dry[i] = s;
    if (Math.abs(s) > peak) peak = Math.abs(s);
  }
}
const norm = 10 ** (-4.5 / 20) / peak;

// —— 写文件 ——

const pcm = Buffer.alloc(44 + N * 4);
pcm.write('RIFF', 0);
pcm.writeUInt32LE(36 + N * 4, 4);
pcm.write('WAVEfmt ', 8);
pcm.writeUInt32LE(16, 16);
pcm.writeUInt16LE(1, 20);
pcm.writeUInt16LE(2, 22);
pcm.writeUInt32LE(SR, 24);
pcm.writeUInt32LE(SR * 4, 28);
pcm.writeUInt16LE(4, 32);
pcm.writeUInt16LE(16, 34);
pcm.write('data', 36);
pcm.writeUInt32LE(N * 4, 40);
for (let i = 0; i < N; i++) {
  for (const [ch, offset] of [
    [mix.l, 0],
    [mix.r, 2],
  ]) {
    // 抖动：把量化误差变成听不出的底噪
    const v = ch[i] * norm * 32767 + rand() - rand();
    pcm.writeInt16LE(Math.max(-32768, Math.min(32767, Math.round(v))), 44 + i * 4 + offset);
  }
}

const out = resolve(dirname(fileURLToPath(import.meta.url)), '../public/bgm.wav');
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, pcm);

// —— 核对用的输出 ——

const db = (v) => (v > 0 ? (20 * Math.log10(v)).toFixed(1).padStart(6) : '  -inf');
function level(b, from = 0, to = N, gain = 1) {
  let sum = 0;
  let top = 0;
  for (let i = from; i < to; i++) {
    sum += b.l[i] * b.l[i] + b.r[i] * b.r[i];
    top = Math.max(top, Math.abs(b.l[i]), Math.abs(b.r[i]));
  }
  return `均方根 ${db(Math.sqrt(sum / (2 * (to - from))) * gain)} dB  峰值 ${db(top * gain)} dB`;
}
if (process.argv.includes('--stats')) {
  console.log('各条总线（进母带之前）');
  for (const [name, b, gain] of MIX) console.log(`  ${name.padEnd(6, '　')} ${level(b, 0, N, gain)}`);
  console.log(`  ${'混响'.padEnd(6, '　')} ${level(wet, 0, N, WET)}`);
  console.log('各段（成品）');
  SECTIONS.forEach(([bar, what], i) => {
    const from = i === 0 ? 0 : Math.round(at(bar) * SR);
    const to = i + 1 < SECTIONS.length ? Math.round(at(SECTIONS[i + 1][0]) * SR) : N;
    console.log(
      `  第 ${String(frameOf(from / SR)).padStart(4)} 帧  ${level(mix, from, to, norm)}  ${what}`,
    );
  });
}
console.log(
  `${out}  ${(N / SR).toFixed(2)} 秒，${(pcm.length / 1e6).toFixed(1)} MB，归一前峰值 ${db(peak)} dB`,
);
