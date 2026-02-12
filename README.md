# S2S-DNS-Sentinel
<img width="1429" height="1015" alt="Microsoft Edge 2026-02-12 10 12 40" src="https://github.com/user-attachments/assets/8b7ad284-c323-4e7c-95a6-2cf0ccc7e68f" />

A specialized PowerShell diagnostic tool for monitoring and comparing Active Directory DNS resolution vs. Public DNS performance over Site-to-Site (S2S) VPN tunnels.



## The "Smoking Gun" Diagnostic
Unlike standard ping monitors, this tool performs **simultaneous, directed queries** for the same external domains against both your **Internal Domain Controllers** and **Public Resolvers (8.8.8.8)**. 

This allows you to instantly distinguish between:
* **VPN/DC Issues:** Internal resolution is slow/failing while Public resolution is healthy.
* **WAN/ISP Issues:** Both Internal and Public resolutions show identical latency spikes or failures.
* **M365 Outages:** Connectivity is healthy, but specific service domains (Teams/Outlook) fail to resolve globally.

## Key Features
* **Comparative Graphing:** Real-time line charts showing side-by-side latency.
* **AD Service Health:** Continuous tracking of `_ldap` SRV records to verify DC site-awareness.
* **Timeline Scrubbing:** Scroll back through historical data to capture micro-outages.
* **PNG Reporting:** One-click export of the current chart view for ISP/Vendor tickets.

## Configuration
Edit the `$InternalDCs` and `$InternalDomain` variables at the top of the script to match your environment.

## Requirements
* Windows PowerShell 5.1 (Run as Administrator)
* .NET Framework 4.5+
