# SUSE's openQA tests
#
# Copyright 2016-2018 SUSE LLC
# SPDX-License-Identifier: FSFAP

# Summary: Test NetworkManager
# Maintainer: rfan1 <richard.fan@suse.com>

use Mojo::Base "consoletest";
use testapi;
use utils;
use transactional;

# the below network confiration is used if we use qemu user net
my $dhcp_server = '10.0.2.2';
my $dns_server = '10.0.2.3';
my $mac_addr;
my $nic_name;
my $local_ip = '10.0.2.15';

sub ping_check {
    $mac_addr = get_var('NICMAC');
    $nic_name = script_output("grep $mac_addr /sys/class/net/*/address |cut -d / -f 5");
    assert_script_run("ping -c 5 $dhcp_server");
    assert_script_run("ping -c 5 $dns_server");
    # disconnect the device
    assert_script_run("nmcli device disconnect $nic_name");
    if (script_run("ping -c 5 $dns_server") == 0) {
        die('The network is still up after disconnection');
    }
    assert_script_run("nmcli device connect $nic_name");
    assert_script_run("ping -c 5 $dhcp_server");
    assert_script_run("ping -c 5 $dns_server");
}

# double check what DNS-Manager is currently used by NetworkManger
sub dns_mgr {
    my $RcManager
      = script_output(
'dbus-send --system --print-reply --dest=org.freedesktop.NetworkManager /org/freedesktop/NetworkManager/DnsManager org.freedesktop.DBus.Properties.Get string:org.freedesktop.NetworkManager.DnsManager string:RcManager'
      );
    my $mode = script_output(
'dbus-send --system --print-reply --dest=org.freedesktop.NetworkManager /org/freedesktop/NetworkManager/DnsManager org.freedesktop.DBus.Properties.Get string:org.freedesktop.NetworkManager.DnsManager string:Mode
        '
    );
    return ($RcManager, $mode);
}

sub run {
    # make sure 'sysconfig' and 'sysconfig-netconfig' are not installed by default
    my @pkgs = ('sysconfig', 'sysconfig-netconfig');
    foreach my $pkg (@pkgs) {
        die "$pkg will not be installed by default on ALP" if (script_run("rpm -q $pkg") == 0);
    }
    my ($RcManager, $mode);
    $mac_addr = get_var('NICMAC');
    $nic_name = script_output("grep $mac_addr /sys/class/net/*/address |cut -d / -f 5");
    # check 'NetworkManager' service is up and it can get right DNS server
    systemctl('is-active NetworkManager');
    assert_script_run('grep "Generated by NetworkManager" /etc/resolv.conf');
    assert_script_run qq(grep "nameserver $dns_server" /etc/resolv.conf);
    # DNS-Manager check
    record_info('default dns bind config');
    ($RcManager, $mode) = dns_mgr();
    die 'wrong DNS-Manager is currently used for default' if ($RcManager !~ /symlink/ || $mode !~ /default/);
    ping_check;
    record_info('chronyd service check');
    assert_script_run('chronyc -n sources');
    # basic nm cli tests
    script_run('nmcli');
    script_run('nmcli device show');
    assert_script_run qq(nmcli device show | grep GENERAL.DEVICE | grep $nic_name);
    assert_script_run qq(nmcli device show | grep IP4.ADDRESS | grep $local_ip);
    assert_script_run qq(nmcli device show | grep IP4.DNS | grep $dns_server);
    ping_check;
    # dnsmasq test
    script_run(
        'cat > /etc/NetworkManager/conf.d/00-use-dnsmasq.conf <<EOF
# This enabled the dnsmasq plugin.
[main]
dns=dnsmasq
EOF
true'
    );
    systemctl('restart NetworkManager');
    # DNS-Manager check
    record_info('with dnsmasq');
    ($RcManager, $mode) = dns_mgr();
    die 'wrong DNS-Manager is currently used for dnsmasq' if ($RcManager !~ /symlink/ || $mode !~ /dnsmasq/);
    ping_check;
    # systemd-resolved
    assert_script_run('rm -rf /etc/NetworkManager/conf.d/00-use-dnsmasq.conf');
    trup_call('pkg install systemd-network');
    check_reboot_changes;
    if (script_run('systemctl enable --now systemd-resolved.service') != 0) {
        record_soft_failure('bsc#1206352  ALP fails to enable service "systemd-resolved.service"');
        return;
    }
    else {
        assert_script_run('ln -rsf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf');
        systemctl('restart NetworkManager');
        record_info('with systemd-resolved');
        # DNS-Manager check
        ($RcManager, $mode) = dns_mgr();
        die 'wrong DNS-Manager is currently used for systemd-resolved' if ($RcManager !~ /unmanaged/ || $mode !~ /systemd-resolved/);
        ping_check;
    }
}

sub test_flags {
    return {always_rollback => 1};
}

1;

