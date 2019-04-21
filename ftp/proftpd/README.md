- [Setup ProFTPd](#setup-proftpd)
  * [Install ProFTPd](#install-proftpd)
  * [Enable virtual users](#enable-virtual-users)
  * [Make Auth Files](#make-auth-files)
  * [Run proftpd service](#run-proftpd-service)
- [Install ftp script](#install-ftp-script)
- [Setting up GameAP](#setting-up-gameap)

## Setup ProFTPd

Example for Debian 9 (Stretch)

### Install ProFTPd

```bash
apt install proftpd
```

### Enable virtual users

Open proftpd configuration:

```bash
nano /etc/proftpd/proftpd.conf
```

Set parameters:
```
DefaultRoot ~
RequireValidShell off
AuthUserFile /etc/proftpd/ftpd.passwd
AuthGroupFile /etc/proftpd/ftpd.group
AuthOrder mod_auth_file.c
```

### Make Auth Files

```bash
touch /etc/proftpd/ftpd.passwd
touch /etc/proftpd/ftpd.group
```

### Run proftpd service

```bash
service proftpd start
```

## Install ftp script

Copy `ftp.sh` to your work directory (default `/srv/gameap`)
You can download `ftp.sh` use wget:
```bash
wget -O /srv/gameap/ftp.sh https://raw.githubusercontent.com/gameap/scripts/master/ftp/proftpd/ftp.sh
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