## rclone access

A specific rclone config is required to fetch RSG sequencing run sample sheets.

```sh
conda install -y -c conda-forge rclone 
rclone config
# name: rsg
# storage: onedrive
# client_id: <LEAVE BLANK>
# client_secret: <LEAVE BLANK>
# region: global
# edit advanced config: n
# use auto config: n
# ... Open a terminal on your local machine, type `rclone authorize "onedrive"` then login from the web page
# config_token: <COPY-PASTE THE TOKEN OBTAINED FROM PREVIOUS STEP>
# config_type: search
# config_search_term: RSG
# config_driveid: 1 (Documents)
# Drive OK: y
rclone ls rsgteams:'Experimentalist group/sequencing_runs/'
```
