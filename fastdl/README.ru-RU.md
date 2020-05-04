Скрипты для модуля [GameAP FastDL Module](https://github.com/gameap/fastdl-module)

* [English](README.md)

## Требования

* Дистрибутив Debian, Ubuntu, CentOS

## Установка FastDL скрипта

* Скопируйте `fastdl.sh` в ваш рабочий каталог (по умолчанию `/srv/gameap`):
```
cd /srv/gameap
wget https://raw.githubusercontent.com/gameap/scripts/master/fastdl/fastdl.sh
```

* Установите права на выполнение:
```
chmod +x fastdl.sh
```
* Выполните команду установки: 
```
./fastdl.sh install
```

## Использование
```
./fastdl.sh КОММАНДА <ОПЦИИ>
```

### Опции

#### Опции создания/удаления
* `--server-path` путь к контент каталогу игрового сервера
* `--method` способ создания fastdl (link, copy, rsync). По умолчанию `link`
* `--web-dir` веб-каталог. По умолчанию `/srv/gameap/fastdl/public`

#### Опции установки
* `--host` Задать хост для Nginx веб сервера
* `--port` Задать порт для Nginx веб сервера
* `--autoindex` Включить автоиндекс

## Примеры

### Установка

Установить и настроить nginx. После установки FastDL должен будет доступен по `fastdl.gameap.ru:1337`. Вместо 
fastdl.gameap.ru укажите свой хост.

```
./fastdl.sh install --autoindex --host=fastdl.gameap.ru --port=1337
```

### Добавить FastDL

Добавить новый FastDL для Counter-Strike сервера. В примере сервер располагается в каталоге: 
`/srv/gaemap/servers/my-cs-server`

```
./fastdl.sh add --server-path=/srv/gaemap/servers/my-cs-server/cstrike
```

### Удалить FastDL

Удалить существующий FastDL для Counter-Strike сервера. В примере сервер располагается в каталоге: 
`/srv/gaemap/servers/my-cs-server`

```
./fastdl.sh delete --server-path=/srv/gaemap/servers/my-cs-server/cstrike
```

## Коды возврата

| Exit code |          Description             |
|-----------|----------------------------------|
|     0     | Успех                            |
|     1     | Ошибка                           |
|     2     | Критическая ошибка               |
|     10    | FastDL аккаунт существует        |
|     11    | FastDL аккаунта не существует    |