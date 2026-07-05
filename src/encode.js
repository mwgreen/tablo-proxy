import { execSync } from 'child_process';

export const IS_LINUX = process.platform === 'linux';
export const FFMPEG = process.env.FFMPEG_PATH || (IS_LINUX ? 'ffmpeg' : '/opt/homebrew/bin/ffmpeg');
export const FFPROBE = process.env.FFPROBE_PATH || (IS_LINUX ? 'ffprobe' : '/opt/homebrew/bin/ffprobe');

// Detect Linux hardware accel: prefer VAAPI, fall back to QSV, then software
export let linuxHwAccel = null;
if (IS_LINUX) {
  try {
    // Check for VAAPI device
    execSync('test -e /dev/dri/renderD128', { stdio: 'ignore' });
    linuxHwAccel = 'vaapi';
  } catch {
    try {
      execSync(`${FFMPEG} -hide_banner -init_hw_device qsv=hw -filter_hw_device hw -f lavfi -i nullsrc -frames:v 1 -c:v h264_qsv -f null - 2>/dev/null`, { stdio: 'ignore' });
      linuxHwAccel = 'qsv';
    } catch {
      // No hardware accel available
    }
  }
}

export function getHwAccelInputArgs() {
  if (!IS_LINUX || !linuxHwAccel) return [];
  if (linuxHwAccel === 'vaapi') {
    return ['-hwaccel', 'vaapi', '-hwaccel_device', '/dev/dri/renderD128', '-hwaccel_output_format', 'vaapi'];
  }
  if (linuxHwAccel === 'qsv') {
    return ['-hwaccel', 'qsv', '-hwaccel_output_format', 'qsv'];
  }
  return [];
}

export function getVideoEncodeArgs() {
  if (IS_LINUX && linuxHwAccel === 'vaapi') {
    return [
      '-c:v', 'h264_vaapi',
      '-rc_mode', 'CQP', '-qp', '24',
      '-profile:v', 'main', '-level', '4.0',
      '-bf', '0',
      // Suppress SEI insertion. The h264_vaapi AU header buffer is hardcoded
      // at 8192 bytes; broadcast OTA sources can produce SEI payloads that
      // exceed it (a53_cc + timing + recovery_point), causing
      // "Access unit too large" encode failures. We can't pass CCs through
      // an all-GPU pipeline anyway (see CC notes), so dropping SEI is free.
      '-sei', '0',
    ];
  }
  if (IS_LINUX && linuxHwAccel === 'qsv') {
    return ['-c:v', 'h264_qsv', '-b:v', '4M', '-profile:v', 'main', '-level', '40'];
  }
  if (IS_LINUX) {
    // Software fallback
    return ['-c:v', 'libx264', '-b:v', '4M', '-profile:v', 'main', '-level', '4.0', '-preset', 'fast'];
  }
  return ['-c:v', 'h264_videotoolbox', '-b:v', '4M', '-profile:v', 'main', '-level', '4.0'];
}
