work-vpn

A small macOS wrapper around openconnect-sso that connects to a work VPN without breaking system networking.

What this does
	•	Connects to a Cisco AnyConnect–compatible VPN using openconnect-sso
	•	Uses a DNS-safe vpnc-script wrapper so the VPN cannot clobber global DNS
	•	Installs scoped DNS only via /etc/resolver/<corp-domain>
	•	Cleans up on exit (routes, resolver files, DHCP), no reboot required™

DNS behaviour (important)
	•	Corporate DNS is scoped, not global
(/etc/resolver/<corp-domain>)
	•	Real resolver files are local-only and ignored by git
	•	Example resolver files (*.example) document the expected shape only

If DNS looks wrong:
	•	Disconnect VPN
	•	Run scutil --dns
	•	Reboot is not required anymore (this is the entire point)

Configuration

Configuration is via .env (not committed):
	•	.env.example documents all required variables
	•	Arrays are supported (bash)
	•	Resolver domains and DNS servers are injected at runtime

Repo conventions
	•	This script is installed on $PATH as work-vpn
	•	All safety rules are enforced by AGENTS.md
	•	No script here is allowed to permanently modify system DNS

Troubleshooting

This script is designed so that disconnecting leaves your Mac usable.
If something is broken, it’s almost always DNS scoping or routing, not “the VPN”.

Quick health check (while connected)

Run these in order:
	•	Confirm VPN routes exist:
	•	route -n get 10.0.0.1
	•	Interface should be utunX, not en0 / en7
	•	Confirm corp DNS is scoped (not global):
	•	scutil --dns | grep -A4 <corp-domain>
	•	You should see nameservers only under that domain
	•	Confirm public DNS still works:
	•	ping google.com
	•	curl https://github.com

If public traffic breaks, global DNS was modified (this is a bug).

If work hosts don’t resolve

Symptoms:
	•	curl: (6) Could not resolve host
	•	getaddrinfo ENOTFOUND

Checks:
	•	ls /etc/resolver
	•	cat /etc/resolver/<corp-domain>

If the file is missing or wrong, recreate it (see below).

If routing looks wrong

Symptoms:
	•	DNS resolves, but connections hang or timeout

Checks:
	•	route -n get <internal-ip>
	•	Gateway must be the VPN utunX interface

If routes are wrong:
	•	Disconnect VPN
	•	Reconnect
	•	Do not try to hand-edit routes unless you enjoy pain

If everything is broken

In order of escalation:
	1.	Disconnect VPN (Ctrl-C)
	2.	Confirm cleanup:
	•	scutil --dns
	•	No corp DNS should appear
	3.	Restart network services:
	•	Toggle Wi-Fi off/on
	4.	Reboot (now optional, not mandatory 🎉)

⸻

Recreating corporate DNS resolvers

If you lose /etc/resolver/* or get a new machine, you can rediscover the correct DNS servers.

Method 1: While VPN is connected (recommended)
	1.	Connect using work-vpn
	2.	Run:
	•	scutil --dns | egrep -A4 '(corp-domain|example)'
	3.	Look for:
	•	nameserver[...] : 10.x.x.x
	•	These are your corporate DNS servers
	4.	Update .env:
	•	WORK_VPN_CORP_DNS_SERVERS=( "10.x.x.x" "10.y.y.y" )

Disconnect and reconnect to confirm.

Method 2: From a working machine

If another machine connects successfully:
	•	Copy the output of:
	•	scutil --dns
	•	Extract the scoped resolver entries
	•	Use those IPs in .env

Method 3: From VPN logs (last resort)

openconnect prints DNS and route information during connect.
Search for lines mentioning:
	•	DNS
	•	INTERNAL_IP4_DNS
	•	CISCO_SPLIT_DNS

These values map directly to resolver entries.

⸻

Safety guarantees (by design)

If this script works correctly:
	•	Global DNS is never modified
	•	Disconnect restores original state
	•	You should never need:
	•	networksetup -setdnsservers ...
	•	random reboot rituals
	•	shouting at your dock

If any of those happen, it’s a bug — fix the script, not the Mac.