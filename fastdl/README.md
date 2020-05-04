Scripts for [GameAP FastDL Module](https://github.com/gameap/fastdl-module)

* [Русский (Russian)](README.ru-RU.md)

## Requirements

* Supported Debian, Ubuntu, CentOS distributives

## Install FastDL script

* Copy `fastdl.sh` to your work directory (default `/srv/gameap`):
```
cd /srv/gameap
wget https://raw.githubusercontent.com/gameap/scripts/master/fastdl/fastdl.sh
```

* Set execute permissions:
```
chmod +x fastdl.sh
```
* Run install command: 
```
./fastdl.sh install
```

## Usage
```
./fastdl.sh COMMAND <OPTIONS>
```

### Options

#### Creating/Deleting options
* `--server-path` path to game server contents directory
* `--method` fastdl make method (link, copy, rsync). Default `link`
* `--web-dir` path to server content web directory. Default `/srv/gameap/fastdl/public`

#### Installation options
* `--host` Set nginx fastdl host.
* `--port` Set nginx fastdl port.
* `--autoindex` Enable nginx autoindex

## Examples

### Install

Install and configure packages (nginx etc.).

```
./fastdl.sh install --autoindex --host=fastdl.gameap.ru --port=1337
```

### Add new FastDL

Add new FastDL for Counter-Strike 1.6 server. Server files example root directory: `/srv/gaemap/servers/my-cs-server`

```
./fastdl.sh add --server-path=/srv/gaemap/servers/my-cs-server/cstrike
```

### Delete FastDL

Delete FastDL for CS server. Server files example root directory: `/srv/gaemap/servers/my-cs-server`

```
./fastdl.sh delete --server-path=/srv/gaemap/servers/my-cs-server/cstrike
```

## Exit codes

| Exit code |          Description             |
|-----------|----------------------------------|
|     0     | Success                          |
|     1     | Common error                     |
|     2     | Critical error                   |
|     10    | FastDL account is already exists |
|     11    | FastDL account doesn't exists    |