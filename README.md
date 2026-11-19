# uid-vpn

A claude-authored CLI tool for connecting or disconnecting to the Ubiquiti UID Enterprise VPN on MacOS. You need to have the GUI VPN client installed. This uses scripting to click on the VPN client in your system tray and then click on the toggle.

You can use this to script turning on the VPN, or to given claude the ability to reconnect your VPN for you. Just be aware that if you're in the middle of typing something or doing somthing, the UID app is going to briefly steal focus, so if you get something to do this in the background, expect it to be annoying.

## Usage

```sh
# Connect to the VPN
$ uid-vpn on

# Disconnect to the VPN
$ uid-vpn off

# Check whether or not you are connected.
# Returns a non-zero status if you are not.
$ uid-vpn status

# Toggle the VPN connection
$ uid-vpn toggle
```

This requires Accessibility permission for the terminal app running it. You should be prompted for access the first time you try to run it.

## Installation

Download the binary from the [releases](https://github.com/jwalton/uid-vpn-cli/releases) page and put it somewhere on your `PATH`.

## Building

```sh
swiftc -O -o ./uid-vpn uid-vpn.swift
```

## How it Works

How it works: UID has no CLI or usable URL hook for the VPN, and the OpenVPN profile it uses is created fresh for each connection and then deleted, so you can't run OpenVPN yourself. Instead, the tool does what you do by hand:

- It finds the UID menu-bar icon and clicks it to open the popover.
- It finds the VPN row in the popover and clicks the switch at the right end of it. The switch isn't visible to macOS's accessibility tools, so the tool clicks a fixed spot near the right end of the row.
- It waits until the UIOvpnClient process starts or stops, then closes the popover.
- It puts your mouse pointer back where it was.
- It restores focus back to your terminal.
