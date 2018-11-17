# Ubuntu Setup & Security Guide
1. generate a root password using `openssl rand -base64 40`. Use this when your cloud provider prompts you to create a password.
2. ssh into server
3. if you need/want to update, run:

       sudo -s -- <<EOF
       apt-get update
       apt-get upgrade -y
       apt-get dist-upgrade -y
       apt-get autoremove -y
       apt-get autoclean -y
       EOF
    
4. run all steps in the *Server Security* section.
5. run all steps in the *Configure Automatic Updates* section.
6. reboot `sudo reboot`
7. ensure that the DNS A record(s) are up to date.


## Server Security
- [Generate fresh sshd host keys](https://www.cyberciti.biz/faq/howto-regenerate-openssh-host-keys/)
  1. Delete old ssh host keys `rm -v /etc/ssh/ssh_host_*`
  2. Regenerate keys `dpkg-reconfigure openssh-server`
  3. Restart the ssh server `sudo systemctl restart ssh`

- [Create admin user](https://askubuntu.com/questions/70236/how-can-i-create-an-administrator-user-from-the-command-line#70240)
  1. `adduser <username>`
  2. `adduser <username> sudo`
  3. test that sudo works by logging in as your new user and running `sudo -v`

- [Disable root login](https://askubuntu.com/questions/27559/how-do-i-disable-remote-ssh-login-as-root-from-a-server)
  1. `sudo vim /etc/ssh/sshd_config` and set `PermitRootLogin no`
  2. Restart the ssh server `sudo service ssh restart`

- [Generate SSH Keypairs](https://www.digitalocean.com/community/tutorials/how-to-set-up-ssh-keys-on-ubuntu-1804)
  1. *Client Side*: Generate keys (if they don't already exist. **Be careful not to overwrite keys, or this could wipe out access to other servers you have previously configured to use cert login**) `ssh-keygen`
  2. *Client Side*: Copy your client's public key to server using `ssh-copy-id <username>@<remote_host>`
  3. *Client Side*: Attempt to log in using `ssh <username>@<remote_host>`. You should not be prompted for a password.
  4. *Server Side*: in the user's `.ssh/authorized_keys` file, verify that the public key in this file matches the public key on your client.

- [Disable password login](https://stackoverflow.com/questions/20898384/ssh-disable-password-authentication)
  1. `sudo vim /etc/ssh/sshd_config` and uncomment and set `PasswordAuthentication no`
  2. Restart the ssh server `sudo service ssh restart`

- [Set a descriptive hostname](https://www.howtogeek.com/197934/how-to-change-your-hostname-computer-name-on-ubuntu-linux/)
  1. edit the hostname in `sudo nano /etc/hosts`
  2. edit the host name in `sudo nano /etc/hostname`

- [Email notifications on login](https://askubuntu.com/questions/179889/how-do-i-set-up-an-email-alert-when-a-ssh-login-is-successful#448602)
  1. install mail tools: `sudo apt install mailutils`
  2. run `sudo vim /etc/ssh/login-notify.sh` to create a script with the content: 

         #!/bin/sh
         # Change these two lines:
         sender="sender-address@example.com"
         recepient="notify-address@example.org"
         
         if [ "$PAM_TYPE" != "close_session" ]; then
             host="`hostname`"
             subject="SSH Login: $PAM_USER from $PAM_RHOST on $host"
             # Message to send, e.g. the current environment variables.
             message="`env`"
             echo "$message" | mailx -r "$sender" -s "$subject" "$recepient"
         fi

  3. mark the script as executable `sudo chmod +x /etc/ssh/login-notify.sh`
  4. run `sudo vim /etc/pam.d/sshd` and add a line `session optional pam_exec.so seteuid /etc/ssh/login-notify.sh`. The `optional` parameter makes it so that if the script fails on login, the user will still be logged in. If the parameter is set to `required`, logins will be blocked if the script does not run successfully.

- [Enable protections against bruteforce login attempts](https://www.linux.com/news/protect-ssh-brute-force-attacks-pamabl)
  1. run `sudo apt-get install libpam-abl` to install pam_abl.
  2. run `sudo vim /etc/security/pam_abl.conf` to edit the pam_abl config. 
     - set `host_rule=*:3/1h` to block any host who fails to connect in 3 tries within 1 hour.
     - set `host_purge=1d` to remove the host blacklist entries after 1 day.
  3. run `sudo service ssh restart` to restart the ssh service.
  4. see [Known Issues](https://wiki.archlinux.org/index.php/Pam_abl#Known_issues) for other considerations.
  5. see who is currently blocked by running `sudo pam_abl`

- Set Timezone
  - `sudo dpkg-reconfigure tzdata`


## [Configure Automatic Updates](https://www.unixmen.com/configure-automatic-updates-ubuntu-server/)
1. run `sudo apt-get install unattended-upgrades`
2. run `sudo vim /etc/apt/apt.conf.d/50unattended-upgrades` and uncomment the line `"${distro_id}:${distro_codename}-updates";`
2. run `sudo vi /etc/apt/apt.conf.d/10periodic`. Set the AutocleanInterval to "7" (the local download archive will now be cleaned every 7 days). Add the line `APT::Periodic::Unattended-Upgrade "1";` to check for updates every day.