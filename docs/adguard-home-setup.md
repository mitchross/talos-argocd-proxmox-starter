# AdGuard Home DNS Server Setup

This guide explains how to set up AdGuard Home as a local DNS server to handle internal DNS resolution while using Cloudflare DNS as the upstream provider.

## Prerequisites

- Docker and Docker Compose installed
- Root or admin access to your machine
- Access to your router's configuration (optional)

## Quick Start

1. Create a new directory for your AdGuard Home setup:
```bash
mkdir adguard-home
cd adguard-home
```

2. Create the following files in your directory:

`docker-compose.yml`:
```yaml
version: '3'
services:
  adguardhome:
    image: adguard/adguardhome
    container_name: adguardhome
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "3000:3000/tcp"
    volumes:
      - ./config:/opt/adguardhome/conf
      - ./work:/opt/adguardhome/work
```

`config/AdGuardHome.yaml`:
```yaml
dns:
  bind_hosts:
    - 0.0.0.0
  port: 53
  rewrites:
    - domain: homepage.vanillax.xyz
      answer: 192.168.10.21
    - domain: argocd.vanillax.xyz
      answer: 192.168.10.21
    - domain: intgw.vanillax.xyz
      answer: 192.168.10.21
    - domain: nginx.vanillax.xyz
      answer: 192.168.10.21
    - domain: test.vanillax.xyz
      answer: 192.168.10.21
    - domain: extgw.vanillax.xyz
      answer: 192.168.10.22
  upstream_dns:
    - https://1.1.1.1/dns-query
    - https://1.0.0.1/dns-query
```

3. Start AdGuard Home:
```bash
docker-compose up -d
```

## Configuring Devices to Use AdGuard Home

### Option 1: Router Configuration (Recommended)
1. Log into your router's admin interface
2. Find the DNS settings (usually under DHCP or Network settings)
3. Set the primary DNS server to the IP address of the machine running AdGuard Home
4. Save settings and restart the router if required

### Option 2: Individual Device Configuration

#### Windows:
1. Open Network & Internet settings
2. Click on "Change adapter options"
3. Right-click your network connection → Properties
4. Select "Internet Protocol Version 4 (TCP/IPv4)" → Properties
5. Select "Use the following DNS server addresses"
6. Enter the IP address of your AdGuard Home server
7. Click OK to save

#### macOS:
1. Open System Preferences → Network
2. Select your active network connection
3. Click "Advanced" → DNS
4. Add (+) the IP address of your AdGuard Home server
5. Click OK and Apply

#### Linux:
Edit `/etc/resolv.conf` or use NetworkManager to set your DNS server to the IP address of your AdGuard Home server.

## Verification
To verify your setup is working:
1. Open a terminal/command prompt
2. Try pinging an internal domain:
```bash
ping homepage.vanillax.xyz
```
It should resolve to 192.168.10.21

## Troubleshooting

### Common Issues:
1. **Port 53 already in use**: 
   - Check if another DNS service is running: `sudo lsof -i :53`
   - Disable system resolved on Linux: `sudo systemctl disable systemd-resolved`

2. **Can't access web interface**:
   - Ensure port 3000 is accessible
   - Check if AdGuard Home container is running: `docker ps`

3. **DNS not resolving**:
   - Verify container is running: `docker-compose ps`
   - Check container logs: `docker-compose logs`
   - Ensure firewall allows port 53 TCP/UDP

### Getting Help
If you encounter issues:
1. Check container logs: `docker-compose logs adguardhome`
2. Visit AdGuard Home's web interface: `http://[your-server-ip]:3000`
3. Verify DNS settings on your device/router

## Security Notes
- The web interface (port 3000) should not be exposed to the internet
- Consider setting up authentication in AdGuard Home's web interface
- Keep Docker and AdGuard Home updated regularly 