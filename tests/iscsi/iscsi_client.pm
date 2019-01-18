# SUSE's openQA tests
#
# Copyright © 2016-2018 SUSE LLC
#
# Copying and distribution of this file, with or without modification,
# are permitted in any medium without royalty provided the copyright
# notice and this notice are preserved.  This file is offered as-is,
# without any warranty.

# Summary: Test suite for iSCSI server and client
#   Multimachine testsuites, server test creates iscsi target and client test uses it
# Maintainer: Jozef Pupava <jpupava@suse.com>

use base "x11test";
use strict;
use testapi;
use mm_network;
use lockapi;
use utils qw(turn_off_gnome_screensaver systemctl);
use y2logsstep;

sub run {
    x11_start_program('xterm -geometry 160x45+5+5', target_match => 'xterm');
    turn_off_gnome_screensaver;
    become_root;
    record_info 'Network', 'Configure MM network - client';
    configure_default_gateway;
    configure_static_ip('10.0.2.3/24');
    configure_static_dns(get_host_resolv_conf());
    mutex_wait('iscsi_target_ready');    # wait for server setup
    record_info 'Target Ready!', 'iSCSI target is configured, start initiator configuration';
    type_string "yast2 iscsi-client\n";
    assert_screen 'iscsi-client', 180;
    send_key "alt-i";                    # go to initiator name field
    wait_still_screen(2, 10);
    type_string "iqn.2016-02.de.openqa";
    wait_still_screen(2, 10);
    assert_screen 'iscsi-initiator-service';
    send_key "alt-v";                    # go to discovered targets tab
    assert_screen 'iscsi-discovered-targets', 120;
    send_key "alt-d";                    # press discovery button
    assert_screen 'iscsi-discovery';
    send_key "alt-i";                    # go to IP address field
    wait_still_screen(2, 10);
    type_string "10.0.2.1";
    assert_screen 'iscsi-initiator-discovered-IP-adress';
    send_key "alt-n";                                     # next
    assert_and_click 'iscsi-initiator-connect-button';    # press connect button
    assert_screen 'iscsi-initiator-connect-manual';
    send_key "alt-n";                                     # go to connected targets tab
    assert_screen 'iscsi-initiator-discovered-targets';
    send_key "alt-n";                                     # next
    assert_screen 'iscsi-initiator-connected-targets';
    send_key "alt-o";                                     # OK
                                                          # logging in to a target will create a local disc device
                                                          # it takes a moment, since udev actually handles it
    sleep 5;
    #wait_still_screen(2, 10);
    record_info 'Systemd', 'Verify status of iscsi services and sockets';
    systemctl("is-active iscsid.service",    expect_false => 0);
    systemctl("is-active iscsid.socket",     expect_false => 0);
    systemctl("is-active iscsi.service",     expect_false => 0);
    systemctl("is-active iscsiuio.service",  expect_false => 1);
    systemctl("is-active iscsiuio.socket",   expect_false => 1);
    systemctl("is-active targetcli.service", expect_false => 1);
    record_info 'Verify LUN availability';
    assert_script_run 'lsscsi';
    assert_script_run 'iscsiadm --mode node session -P 1';
    assert_script_run 'ls /dev/disk/by-path';
    assert_script_run 'lsblk --scsi';
    # making a single partition actually causes the kernel code to re-read the starting part of the disc
    # in order for it to recognize that you now have a partition table when before there was none
    assert_script_run "echo -e \"n\\np\\n1\\n\\n\\nw\\n\" \| fdisk /dev/sda";    # create one partition
    sleep 2;
    assert_script_run 'mkfs.ext4 /dev/sda1';                                     # format partition to ext4
    sleep 2;
    assert_script_run 'mount /dev/sda1 /mnt';                                    # mount partition to /mnt
    assert_script_run 'echo "iscsi is working" > /mnt/iscsi';                    # write text to file on iscsi disk
    assert_script_run 'grep "iscsi is working" /mnt/iscsi';                      # grep expected text from file
    mutex_create('iscsi_initiator_ready');
    mutex_wait('iscsi_display_sessions');
    record_info 'Logout iSCSI', 'Logout iSCSI sessions & unmount LUN';
    assert_script_run 'iscsiadm --mode node --logoutall=all';                    # log out from target
    assert_script_run 'umount /mnt';
    type_string "killall xterm\n";
}

sub post_fail_hook {
    my $self = shift;

    $self->save_upload_y2logs;
}

1;
