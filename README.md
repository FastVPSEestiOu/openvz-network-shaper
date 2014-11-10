This script can restrict both incoming and outgoing speed for OpenVZ (OpenVZ 2.6.18 and 2.6.32 supported) containters for IPv4 and IPv6 support.

Author: Pavel Odintsov / pavel.odintsov [at] gmail.com

Compatilbility:
* Virtuozzo
* Parallels Cloud Server
* OpenVZ/RHEL5 2.6.18
* OpenVZ/RHEL6 2.6.32

Features:
* Complete IPv4 and IPv6 traffic shaping
* Very fast hash based filetring rules (only 2 lookups for thousands of filters)
* Incoming and outgoing traffic shaping (please be very careful with INCOMING shaping features!)

FAQ
* License? GPLv2 (please be careful because we changed license at 10 Nov 2014)
* Did you have support for multiple IPs per containter? Yes!
* How I can manage speed for different CT? You need change only one Perl function.

Installing
* Put fastvps_openvz_shaper.pl into PATH folder (e.g. /usr/bin)
* Put fastvps_openvz_shaper_config to /etc/ folder (it's config with some logic)
* Change Perl subroutine in fastvps_openvz_shaper_config to your speed determining logic (by default all CT shaped to 30mbps)
