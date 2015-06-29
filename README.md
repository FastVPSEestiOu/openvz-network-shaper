This script can restrict both incoming and outgoing speed for OpenVZ (OpenVZ 2.6.18 and 2.6.32 supported) containters and provide IPv4 and IPv6 support.

Author: Pavel Odintsov / pavel.odintsov [at] gmail.com

Compatilbility:
* Parallels Virtuozzo
* Parallels Cloud Server
* OpenVZ/RHEL5 2.6.18
* OpenVZ/RHEL6 2.6.32

Features:
* venet support 
* Rock stable, tested very thoroughly for many years
* Tc and HTB based 
* Complete IPv4 and IPv6 traffic shaping
* Very fast hash based filtering rules (only 2 lookups for thousands of filters)
* Incoming and outgoing traffic shaping (please be very careful with INCOMING shaping feature!)

FAQ
* How much IP's I could have on single server? Tested up to few thousands 
* What license? GPLv2 (please be careful because we changed license at 10 Nov 2014)
* Do you have support for multiple IPs per containter? Yes!
* Do you have support for IPv6? Yes, we have it!
* Do you have veth support? Unfortunately, not because IP configuration for veth is not standard.
* How I can manage speed for different CT? You need change only one Perl function.

Installing
* Install required Perl module: ```yum install -y perl-Net-CIDR-Lite```
* Put fastvps_openvz_shaper.pl into PATH folder (e.g. /usr/bin)
* Put fastvps_openvz_shaper_config to /etc/ folder (it's config with some logic)
* Change Perl subroutine in fastvps_openvz_shaper_config to your speed determining logic (by default all CT shaped to 30mbps)
* Add fastvps_openvz_shaper.pl to cron for run every 10-60 minutes.

Please be careful! We can't restrict incoming speed from external Internet to customer but we can slow down speed from hardware node to customer. 
