# 自制踩雪音效

这六个单声道PCM WAV由本项目的`tools/generate_snow_audio.py`程序合成，没有使用第三方录音或下载素材。

- 44.1 kHz、16 bit、mono，每个约0.29–0.32秒。
- 内容为柔和压雪噪声和细碎颗粒，没有音乐、环境循环或对白。
- `manifest.json`记录生成来源、时长、峰值和RMS。
- 在项目根目录执行`python tools/generate_snow_audio.py`可以确定性重新生成。
- 这是原型音效，真实感与听感需要用户试听；后续替换录音时应另行记录素材来源。
