package opensusebasetest;
use base 'basetest';

use bootloader_setup qw(boot_local_disk tianocore_enter_menu zkvm_add_disk zkvm_add_pty zkvm_add_interface type_hyperv_fb_video_resolution);
use testapi;
use strict;
use utils;


# Base class for all openSUSE tests

sub new {
    my ($class, $args) = @_;
    my $self = $class->SUPER::new($args);
    $self->{in_wait_boot} = 0;
    return $self;
}

# Additional to backend testapi 'clear-console' we do a needle match to ensure
# continuation only after verification
sub clear_and_verify_console {
    my ($self) = @_;

    clear_console;
    assert_screen('cleared-console');

}

sub post_run_hook {
    my ($self) = @_;
    # overloaded in x11 and console
}

sub save_and_upload_log {
    my ($self, $cmd, $file, $args) = @_;
    script_run("$cmd | tee $file", $args->{timeout});
    upload_logs($file) unless $args->{noupload};
    save_screenshot if $args->{screenshot};
}

sub problem_detection {
    my $self = shift;

    type_string "pushd \$(mktemp -d)\n";

    # Slowest services
    $self->save_and_upload_log("systemd-analyze blame", "systemd-analyze-blame.txt", {noupload => 1});
    clear_console;

    # Generate and upload SVG out of `systemd-analyze plot'
    $self->save_and_upload_log('systemd-analyze plot', "systemd-analyze-plot.svg", {noupload => 1});
    clear_console;

    # Failed system services
    $self->save_and_upload_log('systemctl --all --state=failed', "failed-system-services.txt", {screenshot => 1, noupload => 1});
    clear_console;

    # Unapplied configuration files
    $self->save_and_upload_log("find /* -name '*.rpmnew'", "unapplied-configuration-files.txt", {screenshot => 1, noupload => 1});
    clear_console;

    # Errors, warnings, exceptions, and crashes mentioned in dmesg
    $self->save_and_upload_log("dmesg | grep -i 'error\\|warn\\|exception\\|crash'", "dmesg-errors.txt", {screenshot => 1, noupload => 1});
    clear_console;

    # Errors in journal
    $self->save_and_upload_log("journalctl --no-pager -p 'err'", "journalctl-errors.txt", {screenshot => 1, noupload => 1});
    clear_console;

    # Tracebacks in journal
    $self->save_and_upload_log('journalctl | grep -i traceback', "journalctl-tracebacks.txt", {screenshot => 1, noupload => 1});
    clear_console;

    # Segmentation faults
    $self->save_and_upload_log("coredumpctl list", "segmentation-faults-list.txt", {screenshot => 1, noupload => 1});
    $self->save_and_upload_log("coredumpctl info", "segmentation-faults-info.txt", {screenshot => 1, noupload => 1});
    # Save core dumps
    type_string "mkdir -p coredumps\n";
    type_string 'awk \'/Storage|Coredump/{printf("cp %s ./coredumps/\n",$2)}\' segmentation-faults-info.txt | sh';
    type_string "\n";
    clear_console;

    # Broken links
    $self->save_and_upload_log(
"find / -type d \\( -path /proc -o -path /run -o -path /.snapshots -o -path /var \\) -prune -o -xtype l -exec ls -l --color=always {} \\; -exec rpmquery -f {} \\;",
        "broken-symlinks.txt",
        {screenshot => 1, noupload => 1});
    clear_console;

    # Binaries with missing libraries
    $self->save_and_upload_log("
IFS=:
for path in \$PATH; do
    for bin in \$path/*; do
        ldd \$bin 2> /dev/null | grep 'not found' && echo -n Affected binary: \$bin 'from ' && rpmquery -f \$bin
    done
done", "binaries-with-missing-libraries.txt", {timeout => 60, noupload => 1});
    clear_console;

    # rpmverify problems
    $self->save_and_upload_log("rpmverify -a | grep -v \"[S5T].* c \"", "rpmverify-problems.txt", {timeout => 1200, screenshot => 1, noupload => 1});
    clear_console;

    # VMware specific
    if (check_var('VIRSH_VMM_FAMILY', 'vmware')) {
        $self->save_and_upload_log('systemctl status vmtoolsd vgauthd', "vmware-services.txt", {screenshot => 1, noupload => 1});
        clear_console;
    }

    script_run 'tar cvvJf problem_detection_logs.tar.xz *';
    upload_logs('problem_detection_logs.tar.xz');
    type_string "popd\n";
}

sub investigate_yast2_failure {
    my ($self) = shift;

    # first check if badlist exists which could be the most likely problem
    if (my $badlist = script_output 'test -f /var/log/YaST2/badlist && cat /var/log/YaST2/badlist | tail -n 20 || true') {
        record_info 'Likely error detected: badlist', "badlist content:\n\n$badlist", 'fail';
    }
    if (my $y2log_internal_error = script_output 'grep -B 3 \'Internal error. Please report a bug report\' /var/log/YaST2/y2log | tail -n 20 || true') {
        record_info 'Internal error in YaST2 detected', "Details:\n\n$y2log_internal_error", 'fail';
    }
    elsif (my $y2log_other_error = script_output 'grep -B 3 \'<3>\' /var/log/YaST2/y2log | tail -n 20 || true') {
        record_info 'Other error in YaST2 detected', "Details:\n\n$y2log_other_error", 'fail';
    }
}

sub export_logs {
    my ($self) = shift;
    select_console 'log-console';
    save_screenshot;

    $self->problem_detection;

    $self->save_and_upload_log('cat /proc/loadavg', '/tmp/loadavg.txt', {screenshot => 1});
    $self->save_and_upload_log('journalctl -b',     '/tmp/journal.log', {screenshot => 1});
    $self->save_and_upload_log('ps axf',            '/tmp/psaxf.log',   {screenshot => 1});

    # Just after the setup: let's see the network configuration
    $self->save_and_upload_log("ip addr show", "/tmp/ip-addr-show.log");

    save_screenshot;

    # check whether xorg logs is exists in user's home, if yes, upload xorg logs from user's
    # home instead of /var/log
    script_run "test -d /home/*/.local/share/xorg ; echo user-xlog-path-\$? > /dev/$serialdev", 0;
    if (wait_serial("user-xlog-path-0", 10)) {
        $self->save_and_upload_log('cat /home/*/.local/share/xorg/X*', '/tmp/Xlogs.log', {screenshot => 1});
    }
    else {
        $self->save_and_upload_log('cat /var/log/X*', '/tmp/Xlogs.log', {screenshot => 1});
    }

    # do not upload empty .xsession-errors
    script_run
      "xsefiles=(/home/*/.xsession-errors*); for file in \${xsefiles[@]}; do if [ -s \$file ]; then echo xsefile-valid > /dev/$serialdev; fi; done",
      0;
    if (wait_serial("xsefile-valid", 10)) {
        $self->save_and_upload_log('cat /home/*/.xsession-errors*', '/tmp/XSE.log', {screenshot => 1});
    }

    $self->save_and_upload_log('systemctl list-unit-files', '/tmp/systemctl_unit-files.log');
    $self->save_and_upload_log('systemctl status',          '/tmp/systemctl_status.log');
    $self->save_and_upload_log('systemctl',                 '/tmp/systemctl.log', {screenshot => 1});

    script_run "save_y2logs /tmp/y2logs_clone.tar.bz2";
    upload_logs "/tmp/y2logs_clone.tar.bz2";
    $self->investigate_yast2_failure();
}

# Set a simple reproducible prompt for easier needle matching without hostname
sub set_standard_prompt {
    my ($self, $user) = @_;
    $testapi::distri->set_standard_prompt($user);
}

sub select_bootmenu_more {
    my ($self, $tag, $more) = @_;

    assert_screen "inst-bootmenu", 15;

    # after installation-images 14.210 added a submenu
    if ($more && check_screen "inst-submenu-more", 1) {
        if (get_var('OFW')) {
            send_key_until_needlematch 'inst-onmore', 'up';
        }
        else {
            send_key_until_needlematch('inst-onmore', 'down', 10, 5);
        }
        send_key "ret";
    }
    if (get_var('OFW')) {
        send_key_until_needlematch $tag, 'up';
    }
    else {
        send_key_until_needlematch($tag, 'down', 10, 3);
    }
    if (get_var('UEFI')) {
        send_key 'e';
        send_key 'down' for (1 .. 4);
        send_key 'end';
        # newer versions of qemu on arch automatically add 'console=ttyS0' so
        # we would end up nowhere. Setting console parameter explicitly
        # See https://bugzilla.suse.com/show_bug.cgi?id=1032335 for details
        type_string_slow ' console=tty1' if get_var('MACHINE', '') =~ /aarch64/;
        # Hyper-V defaults to 1280x1024, we need to fix it here
        type_hyperv_fb_video_resolution if check_var('VIRSH_VMM_FAMILY', 'hyperv');
        send_key 'f10';
    }
    else {
        type_hyperv_fb_video_resolution if check_var('VIRSH_VMM_FAMILY', 'hyperv');
        send_key 'ret';
    }
}

sub export_kde_logs {
    select_console 'log-console';
    save_screenshot;

    if (check_var("DESKTOP", "kde")) {
        if (get_var('PLASMA5')) {
            my $fn = '/tmp/plasma5_configs.tar.bz2';
            my $cmd = sprintf 'tar cjf %s /home/%s/.config/*rc', $fn, $username;
            type_string "$cmd\n";
            upload_logs $fn;
        }
        else {
            my $fn = '/tmp/kde4_configs.tar.bz2';
            my $cmd = sprintf 'tar cjf %s /home/%s/.kde4/share/config/*rc', $fn, $username;
            type_string "$cmd\n";
            upload_logs $fn;
        }
        save_screenshot;
    }
}

# Our aarch64 setup fails to boot properly from an installed hard disk so
# point the firmware boot manager to the right file.
sub handle_uefi_boot_disk_workaround {
    my ($self) = @_;
    record_info 'workaround', 'Manually selecting boot entry, see bsc#1022064 for details';
    tianocore_enter_menu;
    send_key_until_needlematch 'tianocore-boot_maintenance_manager', 'down', 5, 5;
    wait_screen_change { send_key 'ret' };
    send_key_until_needlematch 'tianocore-boot_from_file', 'down';
    wait_screen_change { send_key 'ret' };
    save_screenshot;
    wait_screen_change { send_key 'ret' };
    # cycle to last entry by going up in the next steps
    # <EFI>
    send_key 'up';
    save_screenshot;
    wait_screen_change { send_key 'ret' };
    # <sles>
    send_key 'up';
    save_screenshot;
    wait_screen_change { send_key 'ret' };
    # efi file
    send_key 'up';
    save_screenshot;
    wait_screen_change { send_key 'ret' };
}

=head2 rewrite_static_svirt_network_configuration

Rewrite the static network configuration within a SUT over the svirt console
based on the worker specific configuration to allow reuse of images created on
one host and booted on another host. Can also be used for debugging in case of
consoles relying on remote connections to within the SUT being blocked by
malfunctioning network or services within the SUT.

Relies on the C<$pty> variable set in the remote svirt shell by C<utils::save_svirt_pty>.

Also see poo#18016 for details.
=cut
sub rewrite_static_svirt_network_configuration {
    my ($self) = @_;
    type_line_svirt "root", expect => 'Password';
    type_line_svirt "$testapi::password";
    my $virsh_guest = get_required_var('VIRSH_GUEST');
    type_line_svirt "sed -i \"\\\"s:IPADDR='[0-9.]*/\\([0-9]*\\)':IPADDR='$virsh_guest/\\1':\\\" /etc/sysconfig/network/ifcfg-\*\"", expect => '#';
    type_string "# output of current network configuration for debugging\n";
    type_line_svirt "cat /etc/sysconfig/network/ifcfg-\*", expect => '#';
    type_line_svirt "systemctl restart network",           expect => '#';
    type_line_svirt "systemctl is-active network",         expect => 'active';
}

=head2 wait_boot

  wait_boot([bootloader_time => $bootloader_time] [, textmode => $textmode] [,ready_time => $ready_time] [,in_grub => $in_grub] [, nologin => $nologin);

Makes sure the bootloader appears and then boots to desktop or text mode
correspondingly. Returns successfully when the system is ready on a login
prompt or logged in desktop. Set C<$textmode> to 1 when the text mode login
prompt should be expected rather than a desktop or display manager.
C<wait_boot> also handles unlocking encrypted disks if needed as well as
various exceptions during the boot process. Also, before the bootloader menu
or login prompt various architecture or machine specific handlings are in
place. The time waiting for the bootloader can be configured with
C<$bootloader_time> in seconds as well as the time waiting for the system to
be fully booted with C<$ready_time> in seconds. Set C<$in_grub> to 1 when the
SUT is already expected to be within the grub menu. C<wait_boot> continues
from there.
=cut
sub wait_boot {
    my ($self, %args) = @_;
    my $bootloader_time = $args{bootloader_time} // 100;
    my $textmode        = $args{textmode};
    my $ready_time      = $args{ready_time} // 200;
    my $in_grub         = $args{in_grub} // 0;
    my $nologin         = $args{nologin};

    # used to register a post fail hook being active while we are waiting for
    # boot to be finished to help investigate in case the system is stuck in
    # shutting down or booting up
    $self->{in_wait_boot} = 1;

    # Reset the consoles after the reboot: there is no user logged in anywhere
    reset_consoles;
    # reconnect s390
    if (check_var('ARCH', 's390x')) {
        my $login_ready = qr/Welcome to SUSE Linux Enterprise Server.*\(s390x\)/;
        if (check_var('BACKEND', 's390x')) {

            console('x3270')->expect_3270(
                output_delim => $login_ready,
                timeout      => $ready_time + 100
            );

            # give the system time to have routes up
            # and start serial grab again
            sleep 30;
            select_console('iucvconn');
        }
        else {
            wait_serial('GNU GRUB') || diag 'Could not find GRUB screen, continuing nevertheless, trying to boot';
            select_console('svirt');
            save_svirt_pty;
            type_line_svirt '', expect => $login_ready, timeout => $ready_time + 100, fail_message => 'Could not find login prompt';
            $self->rewrite_static_svirt_network_configuration();
        }

        # on z/(K)VM we need to re-select a console
        if ($textmode || check_var('DESKTOP', 'textmode')) {
            select_console('root-console');
        }
        else {
            select_console('x11', await_console => 0);
        }
    }
    # On Xen PV and svirt we don't see a Grub menu
    elsif (!(check_var('VIRSH_VMM_FAMILY', 'xen') && check_var('VIRSH_VMM_TYPE', 'linux') && check_var('BACKEND', 'svirt'))) {
        my @tags = ('grub2');
        push @tags, 'bootloader-shim-import-prompt'   if get_var('UEFI');
        push @tags, 'boot-live-' . get_var('DESKTOP') if get_var('LIVETEST');    # LIVETEST won't to do installation and no grub2 menu show up
        push @tags, 'bootloader'                      if get_var('OFW');
        push @tags, 'encrypted-disk-password-prompt'  if get_var('ENCRYPT');
        if (get_var('ONLINE_MIGRATION')) {
            push @tags, 'migration-source-system-grub2';
        }
        # after gh#os-autoinst/os-autoinst#641 68c815a "use bootindex for boot
        # order on UEFI" the USB install medium is priority and will always be
        # booted so we have to handle that
        # because of broken firmware, bootindex doesn't work on aarch64 bsc#1022064
        push @tags, 'inst-bootmenu' if ((get_var('USBBOOT') and get_var('UEFI')) || (check_var('ARCH', 'aarch64') and get_var('UEFI')) || get_var('OFW'));
        $self->handle_uefi_boot_disk_workaround if (get_var('MACHINE') =~ qr'aarch64' && get_var('BOOT_HDD_IMAGE') && !$in_grub);
        check_screen(\@tags, $bootloader_time);
        if (match_has_tag("bootloader-shim-import-prompt")) {
            send_key "down";
            send_key "ret";
            assert_screen "grub2", 15;
        }
        elsif (match_has_tag("migration-source-system-grub2") or match_has_tag('grub2')) {
            send_key "ret";    # boot to source system
        }
        elsif (get_var("LIVETEST")) {
            # prevent if one day booting livesystem is not the first entry of the boot list
            if (!match_has_tag("boot-live-" . get_var("DESKTOP"))) {
                send_key_until_needlematch("boot-live-" . get_var("DESKTOP"), 'down', 10, 5);
            }
            send_key "ret";
        }
        elsif (match_has_tag('inst-bootmenu')) {
            # assuming the cursor is on 'installation' by default and 'boot from
            # harddisk' is above
            send_key_until_needlematch 'inst-bootmenu-boot-harddisk', 'up';
            boot_local_disk;
            assert_screen 'grub2', 15;
            # confirm default choice
            send_key 'ret';
        }
        elsif (match_has_tag('encrypted-disk-password-prompt')) {
            # unlock encrypted disk before grub
            workaround_type_encrypted_passphrase;
            assert_screen "grub2", 15;
        }
        elsif (!match_has_tag("grub2")) {
            # check_screen timeout
            die "needle 'grub2' not found";
        }
    }

    # On Xen we have to re-connect to serial line as Xen closed it after restart
    if (check_var('VIRSH_VMM_FAMILY', 'xen')) {
        wait_serial("reboot: (Restarting system|System halted)") if check_var('VIRSH_VMM_TYPE', 'linux');
        console('svirt')->attach_to_running;
        select_console('sut');
    }

    # on s390x svirt is encryption unlocked with workaround_type_encrypted_passphrase before this wait_boot
    unlock_if_encrypted if !get_var('S390_ZKVM');

    if ($textmode || check_var('DESKTOP', 'textmode')) {
        my $textmode_needles = [qw(linux-login emergency-shell emergency-mode)];
        # Soft-fail for user_defined_snapshot in extra_tests_on_gnome and extra_tests_on_gnome_on_ppc
        # if not able to boot from snapshot
        if (get_var('TEST') !~ /extra_tests_on_gnome/) {
            assert_screen $textmode_needles, $ready_time;
        }
        elsif (!check_screen $textmode_needles, $ready_time) {
            # We are not able to boot due to bsc#980337
            record_soft_failure 'bsc#980337';
            # Switch to root console and continue
            select_console 'root-console';
        }

        handle_emergency if (match_has_tag('emergency-shell') or match_has_tag('emergency-mode'));

        reset_consoles;
        $self->{in_wait_boot} = 0;
        return;
    }

    mouse_hide();

    if (get_var("NOAUTOLOGIN") || get_var("XDMUSED")) {
        assert_screen [qw(displaymanager emergency-shell emergency-mode)], $ready_time;
        handle_emergency if (match_has_tag('emergency-shell') or match_has_tag('emergency-mode'));

        if (!$nologin) {
            if (get_var('DM_NEEDS_USERNAME')) {
                type_string "$username\n";
            }
            # log in
            #assert_screen "dm-password-input", 10;
            elsif (check_var('DESKTOP', 'gnome')) {
                # In GNOME/gdm, we do not have to enter a username, but we have to select it
                send_key 'ret';
            }

            assert_screen 'displaymanager-password-prompt', no_wait => 1;
            type_password $password. "\n";
        }
        else {
            mouse_hide(1);
            $self->{in_wait_boot} = 0;
            return;
        }
    }

    assert_screen [qw(generic-desktop emergency-shell emergency-mode)], $ready_time + 100;
    handle_emergency if (match_has_tag('emergency-shell') or match_has_tag('emergency-mode'));
    mouse_hide(1);
    $self->{in_wait_boot} = 0;
}

sub enter_test_text {
    my ($self, $name, %args) = @_;
    $name       //= 'your program';
    $args{cmd}  //= 0;
    $args{slow} //= 0;
    for (1 .. 13) { send_key 'ret' }
    my $text = "If you can see this text $name is working.\n";
    $text = 'echo ' . $text if $args{cmd};
    if ($args{slow}) {
        type_string_slow $text;
    }
    else {
        type_string $text;
    }
}

# useful post_fail_hook for any module that calls wait_boot
#
# we could use the same approach in all cases of boot/reboot/shutdown in case
# of wait_boot, e.g. see `git grep -l reboot | xargs grep -L wait_boot`
sub post_fail_hook {
    my ($self) = @_;
    return unless $self->{in_wait_boot};
    # In case the system is stuck in shutting down or during boot up, press
    # 'esc' just in case the plymouth splash screen is shown and we can not
    # see any interesting console logs.
    send_key 'esc';
}

1;
# vim: set sw=4 et:
