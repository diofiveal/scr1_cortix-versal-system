# Cortix-SCR1 + Linux на ALINX VD100

## Статус и границы проверки

Исходная аппаратная сборка пользователя рабочая: timing закрыт, Device Image
успешно получен. Новая Linux-конфигурация меняет CIPS/NoC/clock tree, поэтому
успех исходной сборки **не является** результатом проверки этого изменения.

Здесь проверены выполнение Tcl-процедур на mock API, синтаксис и подготовка
конфигурации. Vivado 2023.2 / PetaLinux 2023.2, экспорт реального XSA, запись SD
и запуск платы в среде автора изменения недоступны. Эти пункты остаются
обязательными проверками на машине пользователя. Ни XSA, ни Linux boot не
объявляются успешно выполненными до реального запуска.

## Что объединено

Из ALINX `VD100_2023.2`, commit `902446432c7d60a2968d96f8b02a7c57e00cc7e6`,
`Demo/course_s2` перенесена конфигурация PS/PMC для этой платы: SD1, eMMC/SD0,
UART0 (115200), GEM0 на MIO, USB, QSPI и PMC I2C. Включены native DDR-пути PMC
и LPD. Камеры, LCD, VDMA и GEM1 через EMIO в минимальный проект не включены;
их device-tree phandles и демонстрационные драйверы не копируются.

Существующие RTL SCR1, control и Boot BRAM не изменены. Сохранены их адреса:

| Область | A72/Linux | SCR1 |
|---|---|---|
| Control | `0xA4000000`, 4 КиБ | `0xFF000000` (alias) |
| Boot BRAM | `0xA4010000`, 64 КиБ | `0xFFFF0000` (alias/reset vector) |
| Readiness GPIO | `0xA4020000`, 4 КиБ | host-only |
| Shared DDR | `0x7F000000`, 16 МиБ | `0x7F000000` |

`reserved-memory/no-map` исключает shared DDR из обычного Linux allocation.
Это не реализует coherency: драйвер/host-loader и cache maintenance потребуются
на следующем этапе. SCR1 не запускается автоматически при загрузке Linux;
readiness GPIO после reset остаётся нулевым. Сейчас цель — Linux shell с
аппаратной подсистемой SCR1, а не выполнение его firmware.

## PLL и тактовые домены

`CIPS/pl0_ref_clk` (nominal 100 МГц) → `pll_pl_scr1/clk_in1`.
`pll_pl_scr1/clk_out1` (requested 90 МГц) → SCR1, FPD AXI clock,
SmartConnect, readiness GPIO, NoC `aclk4`, `slowest_sync_clk`, `pl_clk_o`.
`pll_pl_scr1/locked` → `proc_sys_reset_0/dcm_locked`.

90 МГц выбраны по контексту ранее закрытого timing, не по старой цели 100 МГц.
Из-за фактического CIPS clock возможны нецелые Hz (ранее около `90000038`).
Tcl читает **текущие** `CONFIG.FREQ_HZ` на выходе PLL и передаёт их внешним
AXI-портам; значения `99999001`/`90000038` не зашиты как реальные результаты.
CCI/PMC/LPD clocks остаются собственными clocks CIPS. Board reference 200 МГц
через IBUFDS питает DDR. Искусственных timing exceptions не добавлено.

## 1. Создание проекта, PDI и XSA (Vivado 2023.2)

Сначала сохрани предыдущий успешный проект и его PDI. Новый build по умолчанию
создаётся в `build/vivado-linux`, отдельно от старого `build/vivado`.
Повторное создание поверх существующего XPR запрещено; открывай существующий
проект либо выбирай новый `build_root` в `project_info.tcl`.

В каталоге репозитория:

```sh
vivado -mode batch -source scripts/scripts/vivado/create_project.tcl
vivado -mode batch -source scripts/scripts/vivado/build_device_image.tcl -tclargs build/vivado-linux/vd100_scr1/vd100_scr1.xpr build/hardware/cortix_scr1.xsa
```

Первый скрипт создаёт BD/wrapper и запускает synthesis. Второй выполняет
implementation → **Generate Device Image** (`write_device_image`, Versal PDI),
проверяет routed setup/hold slack и Error DRC, затем экспортирует:

```tcl
write_hw_platform -fixed -include_bit build/hardware/cortix_scr1.xsa
```

Если PDI уже успешно получен в **новом Linux-проекте**, достаточно:

```sh
vivado -mode batch -source scripts/scripts/vivado/export_xsa.tcl -tclargs build/vivado-linux/vd100_scr1/vd100_scr1.xpr build/hardware/cortix_scr1.xsa
```

Экспорт отказывается от stale implementation, отсутствующего PDI/PLL/native
DDR routes, отрицательных setup/hold slack и Error DRC. Повторный экспорт не
перезаписывает существующий XSA: укажи новое имя. Дополнительно проверь отчёты
в `build/hardware/reports`: отсутствие необъяснённых unconstrained paths,
unsafe CDC, ошибки DDR pins и всех критических предупреждений.

## 2. PetaLinux 2023.2 из Cortix-XSA

Используй поддерживаемый PetaLinux Linux-host, **обычного пользователя** и
одинаковый релиз 2023.2 для Vivado/PetaLinux. Пример из каталога репозитория:

```sh
source /absolute/path/to/petalinux/2023.2/settings.sh
python3 scripts/scripts/linux/prepare_petalinux.py build/hardware/cortix_scr1.xsa build/petalinux-cortix
bash scripts/scripts/linux/build_sd.sh build/petalinux-cortix
```

`prepare_petalinux.py` создаёт новый template `versal`, импортирует ровно один
Cortix-XSA, применяет настройки SD/ext4 и наш минимальный device tree. Он не
перезаписывает существующий PetaLinux-проект и не использует старые ALINX
`system.xsa`, PDI, `BOOT.bin`, `image.ub` или host-specific offline paths.
Проверяются HWH-маркеры Cortix и наличие его PDI; это проверка идентичности,
не эквивалент hardware validation. SHA256 XSA сохраняется в handoff manifest.

Полная команда packaging для Versal:

```sh
petalinux-package --boot --format BIN --plm --psmfw --u-boot --dtb --force
```

Результат сборки: `build/petalinux-cortix/cortix-sd/`:

- `BOOT.BIN` — boot chain с **Cortix PDI**;
- `image.ub` — kernel/FIT;
- `boot.scr` — U-Boot boot script;
- `rootfs.tar.gz` — ext4 root filesystem;
- `handoff.json`, `SHA256SUMS` — идентичность XSA/образов.

Директория staging должна быть новой. Для повторной сборки сохрани/переименуй
старую `cortix-sd`, чтобы не смешивать поколения образов. Для offline builds
настрой cache/downloads в этом новом проекте под пути **своей** машины.

## 3. SD и контрольный Linux boot

Скрипты не форматируют и не записывают block devices. Используй уже проверенную
SD с разделами FAT32 `BOOT` и ext4 `ROOTFS` либо подготовь новую по ALINX guide.
Сначала сделай резервную копию: обновление файлов BOOT/rootfs заменяет систему.
Не выбирай `/dev/sdX` по догадке; проверь карту и её mountpoints через `lsblk -f`.

В Ubuntu, после проверки **конкретных** mountpoints:

```sh
payload=/absolute/path/to/repo/build/petalinux-cortix/cortix-sd
boot_mount=/absolute/mountpoint/of/SD/BOOT
rootfs_mount=/absolute/mountpoint/of/SD/ROOTFS
cd "$payload"
sha256sum -c SHA256SUMS
cp BOOT.BIN image.ub boot.scr "$boot_mount/"
sudo tar --numeric-owner -xzpf rootfs.tar.gz -C "$rootfs_mount/"
sync
```

На повторно используемой BOOT не оставляй отдельные старые `system.dtb`, `Image`
или другие boot images: U-Boot может выбрать их вместо нового FIT. Сохрани их
в backup вне BOOT. ROOTFS предпочтительно разворачивать на чистом ext4-разделе,
чтобы не остались старые конфиги/сервисы ALINX; форматирование требует отдельной
проверки выбранного устройства, не выполняется этими скриптами.

Безопасно извлеки SD, выставь SD boot mode по ALINX VD100 guide, вставь карту,
подключи UART (115200, 8N1, no flow control) и перезапусти питание платы.
Сохрани полный UART log от PLM до shell.

Конфигурация соответствует ALINX: eMMC на SD0, SD-карта на SD1,
rootfs `/dev/mmcblk1p2`. При `Waiting for root device` проверь фактическую
нумерацию в boot log и `printenv bootargs` в U-Boot; не обходи проблему
непроверенным старым `BOOT.bin`. Проверить размер RAM: 2 ГиБ DDR, 16 МиБ shared
region зарезервировано и не выдаётся Linux allocator.

Login `petalinux`, установи пароль при первом входе. Для root shell выполни
`sudo -i` (или используй уже настроенный root-пароль). Пустой root-пароль и
открытый SSH-root не включаются. Контрольная точка:

```text
root@petalinux:~#
```

После загрузки сохрани `uname -a`, `cat /proc/cmdline`, `lsblk -f`,
`dmesg | grep -Ei 'mmc|DDR|reserved|error|fail'`. Достижение этого shell с новыми
согласованными образами подтверждает Linux bring-up, но ещё не проверяет
bootloader/тесты SCR1. Доступ к PL MMIO проверяй после clock/reset readiness,
не делай слепой `devmem` в неотвечающий AXI target.

## Локальные regression checks

```sh
python3 scripts/scripts/checks/test_linux_integration.py
bash -n scripts/scripts/linux/build_sd.sh
```

Тесты исполняют production Tcl на **mock Vivado API** и проверяют частоты,
locked/reset, CIPS overlay, native NoC paths, карту адресов, Kconfig merge и
защитные отказы XSA export. Они не синтезируют IP, не заменяют Vivado и не
эмулируют реальную загрузку Versal.

## Источники

- [ALINX course_s2](https://github.com/alinxalinx/VD100_2023.2/tree/902446432c7d60a2968d96f8b02a7c57e00cc7e6/Demo/course_s2)
- [ALINX PetaLinux workflow](https://github.com/alinxalinx/VD100_2023.2/blob/902446432c7d60a2968d96f8b02a7c57e00cc7e6/Demo/course_s2/documentations/EN/2_About_PETALINUX.md)
- [AMD UG1144 2023.2: boot packaging](https://docs.amd.com/r/2023.2-English/ug1144-petalinux-tools-reference-guide/petalinux-package-boot-Examples)
- [AMD UG835 2023.2: write_hw_platform](https://docs.amd.com/r/2023.2-English/ug835-vivado-tcl-commands/write_hw_platform)
