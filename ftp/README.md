Scripts for [GameAP FTP Module](https://github.com/gameap/ftp-module)

* [ProFTPd](https://github.com/gameap/scripts/tree/master/ftp/proftpd)
* [Pure-FTPd Server](https://github.com/gameap/scripts/tree/master/ftp/pure-ftpd)

## Install FTP script

Copy `ftp.sh` to your work directory (default `/srv/gameap`)

## Setting up GameAP 

In your panel go to **FTP** -> **Commands**.

Create Command: 
`./ftp.sh add --username="{username}" --password="{password}" --directory="{dir}"`

Update Command:
`./ftp.sh update --username="{username}" --password="{password}" --directory="{dir}"`

Delete Command:
`./ftp.sh delete --username="{username}""`