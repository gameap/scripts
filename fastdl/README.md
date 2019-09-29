Scripts for [GameAP FTP Module](https://github.com/gameap/fastdl-module)

## Requirements

* Supported Debian, Ubuntu, CentOS distributives

## Install FTP script

* Copy `fastdl.sh` to your work directory (default `/srv/gameap`):
```
cd /srv/gameap
wget https://raw.githubusercontent.com/gameap/scripts/master/fastdl/nginx-site.conf
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

* `--server-path` path to game server root directory
* `--method` fastdl make method (link, copy, rsync). Default `link`
* `--web-dir` path to server content web directory. Default `/srv/gameap/fastdl/public`
* `--host` installation option. Set nginx fastdl host.
* `--port` installation option. Set nginx fastdl port.
* `--autoindex` installation option. Enable nginx autoindex

## Example

### Create new 
```

```