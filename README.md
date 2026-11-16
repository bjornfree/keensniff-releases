# KeenSniff Releases

Публичные сборки KeenSniff для роутеров Keenetic с Entware.

## Установка одной командой

```sh
(command -v curl >/dev/null 2>&1 || { opkg update && opkg install curl; }) && curl -fsSL https://raw.githubusercontent.com/bjornfree/keensniff-releases/main/install.sh | sh
```

Поддерживаются arm64, mipsle, mips и arm.

[Описание изменений](CHANGELOG.md) · [Исходный код](https://gitverse.ru/bjornfree/KeenSniff)
