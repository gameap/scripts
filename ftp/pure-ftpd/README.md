- [Setup Pure-FTPd](#setup-pure-ftpd)
  * [Install Pure-FTPd](#install-pure-ftpd)
  * [Enable virtual users](#enable-virtual-users)
  * [Make Pure-FTPd database file](#make-pure-ftpd-database-file)
  * [Run Pure-FTPd Service](#run-pure-ftpd-service)
- [Install ftp script](#install-ftp-script)
- [Setting up GameAP](#setting-up-gameap)

## Setup Pure-FTPd

Example for Debian 9 (Stretch)

### Install Pure-FTPd

```bash
apt install pure-ftpd
```

### Enable virtual users

```bash
ln -s /etc/pure-ftpd/conf/PureDB /etc/pure-ftpd/auth/50pure
```

### Make Pure-FTPd database file

```bash
pure-pw mkdb
```

### Run Pure-FTPd Service

```bash
service pure-ftpd start
```

## Install ftp script

Copy `ftp.sh` to your work directory (default `/srv/gameap`)
You can download `ftp.sh` use wget:
```bash
wget -O /srv/gameap/ftp.sh https://raw.githubusercontent.com/gameap/scripts/master/ftp/pure-ftp/ftp.sh
chmod +x /srv/gameap/ftp.sh
```

## Setting up GameAP 

In your panel go to **FTP** -> **Commands**.

Create Command: 
`./ftp.sh add --username="{username}" --password="{password}" --directory="{dir}"`

Update Command:
`./ftp.sh update --username="{username}" --password="{password}" --directory="{dir}"`

Delete Command:
`./ftp.sh delete --username="{username}""`