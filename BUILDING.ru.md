### [English](BUILDING.md) · Русский

# Сборка прошивки

[← README](README.ru.md)

## Что нужно
* Linux на x86-64 с Docker.
* Обычный пользователь (не root) в группе `docker`.
* 20 ГБ свободного места на файловой системе ext4.

## Сборка
```bash
git clone -b a5v4-25.12 https://github.com/Dreyk007/openwrt-archer-a5v4-c50v4.git
cd openwrt-archer-a5v4-c50v4
docker/run.sh ./build.sh --ccache
```
Сборка идёт с настройками релизов. Первая сборка компилирует ещё и тулчейн и идёт долго; следующие перекомпилируют только
изменённое.

Прошивка — `bin/targets/ramips/mt76x8/openwrt-ramips-mt76x8-tplink_archer-c50-v4-squashfs-sysupgrade.bin`. Установите её, как
описано в [README](README.ru.md#установка).

## Проверка в QEMU
Перед установкой проверьте образ на стенде QEMU:
```bash
sudo modprobe -a tun ppp_generic
docker/run.sh ./build.sh --qemu --ccache
docker/run.sh --bench tests/qemu/bench.sh
```
Прогон заканчивается строкой `Failed: 0, skipped: 0`.

## Изменение конфигурации
1. Откройте оболочку в контейнере сборки: `docker/run.sh`.
2. В контейнере:
   ```bash
   cp a5v4.config .config && make defconfig
   make menuconfig
   ./scripts/diffconfig.sh > a5v4.config
   exit
   ```
3. Параметры ядра меняйте в `a5v4-kernel.config`.
4. Соберите заново: `docker/run.sh ./build.sh --ccache`. Если образ не помещается во флеш, сборка останавливается.
   `size-report.txt` рядом с прошивкой показывает, сколько места остаётся под настройки.

## GitHub Actions
Выпуск релиза из своего репозитория на GitHub:
1. *Settings → Actions → General*: выберите *Allow all actions and reusable workflows*.
2. В *Actions* отключите все workflow, кроме *Build Archer A5 v4 / C50 v4 firmware*: откройте каждый и выберите
   *⋯ → Disable workflow*.
3. *Settings → General → Releases*: выберите *Enable release immutability*.
4. *Actions → Build Archer A5 v4 / C50 v4 firmware → Run workflow*, поля не меняйте.

Релиз появится в *Releases* с тегом `v<версия OpenWrt>-a5v4-r<N>`.

**Проверка скачанного образа.** К каждому файлу релиза прилагается подписанное подтверждение запуска workflow, который его
собрал. Проверить скачанный образ можно через [GitHub CLI](https://cli.github.com/):
```bash
gh attestation verify openwrt-ramips-mt76x8-tplink_archer-c50-v4-squashfs-sysupgrade.bin --repo Dreyk007/openwrt-archer-a5v4-c50v4
gh release verify-asset <тег релиза> openwrt-ramips-mt76x8-tplink_archer-c50-v4-squashfs-sysupgrade.bin --repo Dreyk007/openwrt-archer-a5v4-c50v4
```
