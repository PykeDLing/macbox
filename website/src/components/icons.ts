// 按 App 里 SF Symbols 的用法选粗细：侧边栏、按钮这类界面图标用 bold（小尺寸下线条不发虚），
// 彩色方块里的图标、状态标签用 fill，空状态的大图标用 regular
import arrowUpRight from '@phosphor-icons/core/bold/arrow-up-right-bold.svg?raw';
import check from '@phosphor-icons/core/bold/check-bold.svg?raw';
import copy from '@phosphor-icons/core/bold/copy-bold.svg?raw';
import desktop from '@phosphor-icons/core/bold/desktop-bold.svg?raw';
import download from '@phosphor-icons/core/bold/download-simple-bold.svg?raw';
import gear from '@phosphor-icons/core/bold/gear-six-bold.svg?raw';
import globe from '@phosphor-icons/core/bold/globe-simple-bold.svg?raw';
import handBold from '@phosphor-icons/core/bold/hand-bold.svg?raw';
import playCircle from '@phosphor-icons/core/bold/play-circle-bold.svg?raw';
import search from '@phosphor-icons/core/bold/magnifying-glass-bold.svg?raw';
import sliders from '@phosphor-icons/core/bold/sliders-horizontal-bold.svg?raw';
import squares from '@phosphor-icons/core/bold/squares-four-bold.svg?raw';
import terminal from '@phosphor-icons/core/bold/terminal-window-bold.svg?raw';
import backgroundServices from '@phosphor-icons/core/bold/gear-fine-bold.svg?raw';
import launchAtLogin from '@phosphor-icons/core/bold/rocket-launch-bold.svg?raw';
import scatteredFiles from '@phosphor-icons/core/bold/files-bold.svg?raw';
import archiveFill from '@phosphor-icons/core/fill/file-zip-fill.svg?raw';
import blockedFill from '@phosphor-icons/core/fill/x-circle-fill.svg?raw';
import cameraFill from '@phosphor-icons/core/fill/camera-fill.svg?raw';
import checkedFill from '@phosphor-icons/core/fill/seal-check-fill.svg?raw';
import cloudFill from '@phosphor-icons/core/fill/cloud-fill.svg?raw';
import cpuFill from '@phosphor-icons/core/fill/cpu-fill.svg?raw';
import desktopFill from '@phosphor-icons/core/fill/desktop-fill.svg?raw';
import doneFill from '@phosphor-icons/core/fill/check-circle-fill.svg?raw';
import downloadFill from '@phosphor-icons/core/fill/download-simple-fill.svg?raw';
import eyeFill from '@phosphor-icons/core/fill/eye-fill.svg?raw';
import eyeSlashFill from '@phosphor-icons/core/fill/eye-slash-fill.svg?raw';
import fileSearchFill from '@phosphor-icons/core/fill/file-magnifying-glass-fill.svg?raw';
import githubFill from '@phosphor-icons/core/fill/github-logo-fill.svg?raw';
import globeFill from '@phosphor-icons/core/fill/globe-simple-fill.svg?raw';
import globeXFill from '@phosphor-icons/core/fill/globe-simple-x-fill.svg?raw';
import handFill from '@phosphor-icons/core/fill/hand-fill.svg?raw';
import houseFill from '@phosphor-icons/core/fill/house-fill.svg?raw';
import hourglassFill from '@phosphor-icons/core/fill/hourglass-medium-fill.svg?raw';
import keyFill from '@phosphor-icons/core/fill/key-fill.svg?raw';
import lockFill from '@phosphor-icons/core/fill/lock-fill.svg?raw';
import meetingFill from '@phosphor-icons/core/fill/video-camera-fill.svg?raw';
import musicFill from '@phosphor-icons/core/fill/music-notes-fill.svg?raw';
import passwordFill from '@phosphor-icons/core/fill/password-fill.svg?raw';
import playFill from '@phosphor-icons/core/fill/play-fill.svg?raw';
import restoreFill from '@phosphor-icons/core/fill/clock-counter-clockwise-fill.svg?raw';
import shieldFill from '@phosphor-icons/core/fill/shield-check-fill.svg?raw';
import swapFill from '@phosphor-icons/core/fill/arrows-left-right-fill.svg?raw';
import trashFill from '@phosphor-icons/core/fill/trash-fill.svg?raw';
import warningFill from '@phosphor-icons/core/fill/warning-fill.svg?raw';
import cursorClick from '@phosphor-icons/core/regular/cursor-click.svg?raw';
import emptyPlay from '@phosphor-icons/core/regular/play-circle.svg?raw';
import emptySearch from '@phosphor-icons/core/regular/magnifying-glass.svg?raw';

export const icons = {
  // 界面
  arrowUpRight,
  check,
  copy,
  desktop,
  download,
  gear,
  playCircle,
  search,
  squares,
  github: githubFill,
  // 状态和操作
  play: playFill,
  lock: lockFill,
  vm: desktopFill,
  working: hourglassFill,
  warning: warningFill,
  blocked: blockedFill,
  trash: trashFill,
  done: doneFill,
  online: globeFill,
  offline: globeXFill,
  // 运行报告的几节
  reportFiles: scatteredFiles,
  reportSettings: sliders,
  reportServers: globe,
  reportPrograms: terminal,
  reportBlocked: handBold,
  // 空状态
  cursorClick,
  emptyPlay,
  emptySearch,
  // “为什么需要它”
  launchAtLogin,
  backgroundServices,
  scatteredFiles,
  // 特性
  house: houseFill,
  key: keyFill,
  swap: swapFill,
  hand: handFill,
  eyeSlash: eyeSlashFill,
  shield: shieldFill,
  restore: restoreFill,
  eye: eyeFill,
  checked: checkedFill,
  report: fileSearchFill,
  // 演示窗口里的应用
  cloud: cloudFill,
  downloadApp: downloadFill,
  meeting: meetingFill,
  music: musicFill,
  cpu: cpuFill,
  camera: cameraFill,
  password: passwordFill,
  archive: archiveFill,
} as const;
