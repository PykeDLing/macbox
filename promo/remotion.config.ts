import { Config } from '@remotion/cli/config';

// 画面是扁平色块和文字，png 截帧避免 jpeg 在细线、小字边缘留下噪点
Config.setVideoImageFormat('png');
Config.setCodec('h264');
// 25 时每版约 2.7 MB，放在网页上看不出和 18（约 5.9 MB）的差别
Config.setCrf(25);
// 配乐：AAC 160 kbps，每版多出约 1 MB
Config.setAudioBitrate('160k');
Config.setOverwriteOutput(true);
