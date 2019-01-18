# SUSE's openQA tests
#
# Copyright © 2016-2019 SUSE LLC
#
# Copying and distribution of this file, with or without modification,
# are permitted in any medium without royalty provided the copyright
# notice and this notice are preserved.  This file is offered as-is,
# without any warranty.

# Summary: Test suite for iSCSI server and client
#    Multimachine testsuites, server test creates iscsi target and client test uses it
# Maintainer: Jozef Pupava <jpupava@suse.com>

use base "x11test";
use strict;
use testapi;
use mm_network;
use mm_tests 'configure_static_network';
use lockapi;
use version_utils qw(is_sle is_leap);
use mmapi;
use utils qw(zypper_call turn_off_gnome_screensaver systemctl);
use yast2_widget_utils 'change_service_configuration';
use y2logsstep;

my %target_conf = (
    ip                 => '10.0.2.1/24',
    lun                => '/root/iscsi-disk',
    acl_target_user    => 'test_target',
    acl_initiator_user => 'test_initiator',
    acl_pass           => 'susetesting',
    name               => 'iqn.2016-02.de.openqa',
    id                 => '132'
);

sub prepare_xterm {
    x11_start_program('xterm -geometry 160x45+5+5', target_match => 'xterm');
    turn_off_gnome_screensaver;
    become_root;
}

sub prepare_iscsi_deps {
    zypper_call 'in yast2-iscsi-lio-server targetcli';
    assert_script_run 'dd if=/dev/zero of=' . $target_conf{lun} . ' seek=1M bs=8192 count=1';    # create iscsi LUN
}

sub target_service_tab {
    assert_screen 'iscsi-lio-server';
    unless (is_sle('<15') || is_leap('<15.1')) {
        change_service_configuration(
            after_writing => {start         => 'alt-w'},
            after_reboot  => {start_on_boot => 'alt-a'}
        );
    } else {
        send_key 'alt-b';
    }
    send_key 'alt-o';    # open port in firewall
    wait_still_screen(2, 10);
    assert_screen 'iscsi-target-overview-service-tab';
}

sub config_2way_authentication {
    assert_screen 'iscsi-target-modify-acls';
    send_key 'alt-a';
    assert_screen 'iscsi-target-modify-acls-initiator-popup';
    if (is_sle('>=15')) {
        send_key 'alt-i';
    } else {
        send_key_until_needlematch 'iscsi-client-name-selected', 'tab';
    }

    type_string $target_conf{name};
    send_key 'alt-o';
    assert_screen 'iscsi-target-modify-acls';
    send_key 'alt-u';
    assert_screen 'iscsi-target-modify-acls-authentication';
    # initiator & target credential fields are swapped in sle12 and sle15
    my %key_shortcuts;
    if (is_sle('>=15')) {
        $key_shortcuts{enable_auth_init}   = 'alt-h';
        $key_shortcuts{auth_init_user}     = 'alt-m';
        $key_shortcuts{auth_init_pass}     = 'alt-t';
        $key_shortcuts{enable_auth_target} = 'alt-n';
        $key_shortcuts{auth_target_user}   = 'alt-u';
        $key_shortcuts{auth_target_pass}   = 'alt-p';

    } else {
        $key_shortcuts{enable_auth_init}   = 'alt-t';
        $key_shortcuts{auth_init_user}     = 'alt-s';
        $key_shortcuts{auth_init_pass}     = 'alt-a';
        $key_shortcuts{enable_auth_target} = 'alt-h';
        $key_shortcuts{auth_target_user}   = 'alt-u';
        $key_shortcuts{auth_target_pass}   = 'alt-p';
    }
    send_key $key_shortcuts{enable_auth_init};
    assert_screen 'iscsi-target-acl-auth-initiator-enable-auth';
    send_key $key_shortcuts{auth_init_user};
    type_string $target_conf{acl_initiator_user};
    assert_screen 'iscsi-target-acl-auth-initiator-username';
    send_key $key_shortcuts{auth_init_pass};
    my $init_pass = reverse $target_conf{acl_pass};
    type_string $init_pass;
    assert_screen 'iscsi-target-acl-auth-initiator-pass' if is_sle('>=15');
    send_key $key_shortcuts{enable_auth_target};
    assert_screen 'iscsi-target-acl-auth-target-enable-auth';
    send_key $key_shortcuts{auth_target_user};
    type_string $target_conf{acl_target_user};
    assert_screen 'iscsi-target-acl-auth-target-username';
    send_key $key_shortcuts{auth_target_pass};
    type_string $target_conf{acl_pass};
    assert_screen 'iscsi-target-acl-auth-target-pass' if is_sle('>=15');
    send_key 'alt-o';
    assert_screen 'iscsi-target-modify-acls';
    send_key 'alt-n';
    if (is_sle('>=15')) {
        assert_screen 'iscsi-target-acl-warning';
        send_key 'alt-y';
    }

}

sub target_backstore_tab {
    send_key 'alt-t';    # go to target tab
    wait_still_screen(2, 10);
    send_key 'alt-a';    # add target
    wait_still_screen(2, 10);
    send_key 'alt-t';    # select target field
    wait_still_screen(2, 10);
    send_key 'ctrl-a';    # select all text inside target field
    wait_still_screen(2, 10);
    send_key 'delete';    # text it is automatically selected after tab, delete
    type_string $target_conf{name};
    wait_still_screen(2, 10);
    send_key 'tab';       # tab to identifier field
    wait_still_screen(2, 10);
    send_key 'delete';
    wait_still_screen(2, 10);
    type_string $target_conf{id};
    if (is_sle('>=15')) {
        wait_still_screen(1);
        send_key 'alt-l';    # un-check bind all IPs
                             # check use authentication only on sle15
                             # checked in sle12 by default
        wait_still_screen(1);
        send_key 'alt-u';
    }
    wait_still_screen(2, 10);
    send_key 'alt-a';        # add LUN
    my $lunpath_key = is_sle('>=15') ? 'alt-l' : 'alt-p';
    send_key_until_needlematch 'iscsi-target-LUN-path-selected', $lunpath_key, 5, 5;    # send $lunpath_key until LUN path is selected
    type_string $target_conf{lun};
    assert_screen 'iscsi-target-LUN';
    send_key 'alt-o';                                                                   # OK
    assert_screen 'iscsi-target-overview';
    send_key 'alt-n';                                                                   # next
    config_2way_authentication;
    assert_screen 'iscsi-target-overview-target-tab';
    send_key 'alt-f';                                                                   # finish
}

sub display_targets {
    my (%args) = @_;
    my $cmd = 'targetcli sessions list';
    assert_script_run 'targetcli ls';
    # targetcli does not support sessions option in sle12
    return if (is_sle '<15');
    $cmd .= '| grep -i ' . $args{expected} if defined($args{expected});
    assert_script_run $cmd;
}

sub run {
    my $self = shift;
    # open xterm, configure server network and create drive for iscsi
    prepare_xterm;
    record_info 'Network', 'Configure MM network - server';
    configure_static_network($target_conf{ip});
    prepare_iscsi_deps;
    # verify iscsi connection before setup
    record_info 'iSCSI Sessions', 'Display target sessions & settings before iscsi configuration';
    display_targets(expected => qq('no open sessions'));
    # start yast2 wizard
    record_info 'iSCSI target', 'Start target configuration';
    type_string "yast2 iscsi-lio-server; echo yast2-iscsi-server-\$? > /dev/$serialdev\n";
    target_service_tab;
    target_backstore_tab;
    wait_serial("yast2-iscsi-server-0", 180) || die "'yast2 iscsi-lio ' didn't finish or exited with non-zero code";
    # verify systemd services after configuration
    record_info 'Systemd - after', 'Verify status of iscsi services and sockets';
    my $service = (is_sle('>=15') ? 'targetcli.service' : 'target.service');
    systemctl("is-active $service", expect_false => 0);
    # create mutex for child job -> triggers start of initiator configuration
    # setup is done client can connect
    mutex_create('iscsi_target_ready');
    my $children = get_children();
    my $child_id = (keys %$children)[0];
    # wait for child mutex, initiator is being configured
    mutex_wait("iscsi_initiator_ready", $child_id, 'Initiator configuration in progress!');
    # verify iscsi connections, ACL must be set!
    record_info 'iSCSI Sessions', 'Display target sessions & settings after setup';
    display_targets(expected => 'LOGGED_IN');
    # initiator can continue to test iscsi drive
    mutex_create('iscsi_display_sessions');
    # wait idle while initiator finishes its execution
    wait_for_children;
    type_string "killall xterm\n";
    $self->result('ok');
}

sub test_flags {
    return {fatal => 1};
}

sub post_fail_hook {

    select_console 'root-console';
    display_targets;
    # show amount of normal logouts
    assert_script_run 'cat /sys/kernel/config/target/iscsi/iqn.2016-02.de.openqa\\:132/fabric_statistics/iscsi_logout_stats/normal_logouts';
    # show amount of abnormal logouts
    assert_script_run 'cat /sys/kernel/config/target/iscsi/iqn.2016-02.de.openqa\\:132/fabric_statistics/iscsi_logout_stats/abnormal_logouts';
    # show amount of active sessions
    assert_script_run 'cat /sys/kernel/config/target/iscsi/iqn.2016-02.de.openqa\\:132/fabric_statistics/iscsi_instance/sessions';
    # show ACL information
    assert_script_run 'cat /sys/kernel/config/target/iscsi/iqn.2016-02.de.openqa\\:132/tpgt_1/acls/iqn.2016-02.de.openqa/info';
    y2logsstep::save_upload_y2logs;

}

1;
