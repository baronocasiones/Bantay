# BANTAY Path 2 phone harness

This Flutter app exercises the local `bantay_llm` module on an Android phone. It shows model load time, fixed alerts, generated results, elapsed time, and whether the LLM text passed the fact check. The sample incident is synthetic; this app does not yet handle a real impact (countdown, SMS), but it does stream live accelerometer data from the Path 1 sensor service: see the **Sensors** tab and `../../docs/path1-module.md`. The detector itself arrives in the next slice of Path 1.

## Requirements

- Android 11 (API 30) or newer, with an `arm64-v8a` CPU.
- USB debugging authorized so `adb devices -l` lists the phone as `device`.
- Flutter and Android SDK/NDK. On this workstation Flutter is at `/home/adrian/flutter` and the writable SDK is at `/home/adrian/codes/appbuilder-stufff/.android-sdk`.
- The model at `/home/adrian/codes/appbuilder-stufff/models/Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm` (329 MiB, md5 `0c63f12e688bc91d1bd4577c9858d262`). It stays out of source control. Do **not** substitute `qwen3_0_6b_mixed_int4.litertlm`: verified on the demo phone, that file ignores its input and returns the same generic greeting for every prompt.

## Build and prepare the phone

From `/home/adrian/codes/appbuilder-stufff/bantay_app`:

```sh
export ANDROID_HOME=/home/adrian/codes/appbuilder-stufff/.android-sdk
export ANDROID_SDK_ROOT="$ANDROID_HOME"
/home/adrian/flutter/bin/flutter build apk --debug --target-platform android-arm64
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

The app expects the model in its private documents directory. For this debug build, sideload it through `run-as` after installing the APK:

```sh
MODEL=Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm
adb push ../models/$MODEL /data/local/tmp/$MODEL
adb shell run-as ph.appbuilders.bantay_app mkdir -p app_flutter
adb shell run-as ph.appbuilders.bantay_app cp /data/local/tmp/$MODEL app_flutter/$MODEL
adb shell run-as ph.appbuilders.bantay_app md5sum app_flutter/$MODEL
adb shell rm /data/local/tmp/$MODEL
```

The `md5sum` must print `0c63f12e688bc91d1bd4577c9858d262`. A truncated sideload produces a model that appears to load and then answers every prompt with a generic greeting.

## Choose a backend

CPU is the default. GPU cuts prefill 2.6x on the demo phone and is the only
backend that changes the bottleneck, but it makes cold load slower:

```sh
/home/adrian/flutter/bin/flutter build apk --debug --target-platform android-arm64 \
  --dart-define=BANTAY_MODEL_PATH=/data/user/0/ph.appbuilders.bantay_app/app_flutter/$MODEL \
  --dart-define=BANTAY_BACKEND=gpu
```

`BANTAY_MODEL_PATH` is only needed for debug builds where the model is
sideloaded rather than placed in the app-private documents directory. Omit it to
use `qwen3_0_6b_mixed_int4.litertlm` as the default filename, which will not load;
see the model note above. The harness shows the active backend next to the cold
load time.

Open **Bantay** on the phone. Wait for **Model ready**, then compose English and Tagalog alerts. Record cold load time, each result's `llmUsed` and elapsed time, and the actual wording. On the demo phone the 2-second timeout selects the fixed alert every time; use the **Raw model diagnostic** buttons to inspect the model's real wording with a 30-second budget. Repeat in airplane mode and after restarting the app.

If `adb devices -l` is empty, set the phone USB mode to **File transfer**, enable **USB debugging**, reconnect, and accept its debugging authorization prompt. A charge-only cable can also prevent USB detection. Do not interpret a passing desktop test as proof that LiteRT loads on the phone.
