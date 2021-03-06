# Copyright © 2016 SUSE LLC
#
# Copying and distribution of this file, with or without modification,
# are permitted in any medium without royalty provided the copyright
# notice and this notice are preserved.  This file is offered as-is,
# without any warranty.

# Summary: Patch SLE qcow2 images before migration (offline)
# Maintainer: Dumitru Gutu <dgutu@suse.de>

use base "consoletest";
use strict;
use testapi;
use utils;
use version_utils qw(sle_version_at_least is_desktop_installed);
use migration;
use registration;
use qam;

sub is_smt_or_module_tests {
    return get_var('SCC_ADDONS', '') =~ /asmm|contm|hpcm|lgm|pcm|tcm|wsm|idu|ids/ || get_var('TEST', '') =~ /migration_offline_sle12sp\d_smt/;
}

sub patching_sle {
    my ($self) = @_;

    set_var("VIDEOMODE",    'text');
    set_var("SCC_REGISTER", 'installation');
    # remember we perform registration on pre-created HDD images
    if (sle_version_at_least('12-SP2', version_variable => 'HDDVERSION')) {
        set_var('HDD_SP2ORLATER', 1);
    }

    assert_script_run("zypper lr && zypper mr --disable --all");
    save_screenshot;
    yast_scc_registration();
    assert_script_run('zypper lr -d');

    # install all patterns
    install_patterns() if (get_var('PATTERNS'));

    # install package from parameter
    install_package() if (get_var('PACKAGES'));

    # add test repositories and logs the required patches
    add_test_repositories();

    if (get_var('MINIMAL_UPDATE')) {
        minimal_patch_system(version_variable => 'HDDVERSION');
        remove_test_repositories;
    }

    if (get_var('FULL_UPDATE')) {
        fully_patch_system();
        type_string "reboot\n";
        $self->wait_boot(textmode => !is_desktop_installed(), ready_time => 600);
        # Go back to the initial state, before the patching
        $self->setup_migration();
    }

    if (get_var('FLAVOR', '') =~ /-(Updates|Incidents)$/ || get_var('KEEP_REGISTERED')) {
        # The system is registered.
        set_var('HDD_SCC_REGISTERED', 1);
        # SKIP the module installation window, from the add_update_test_repo test
        set_var('SKIP_INSTALLER_SCREEN', 1) if get_var('MAINT_TEST_REPO');

    }
    else {
        scc_deregistration(version_variable => 'HDDVERSION');
    }
    remove_ltss;
    assert_script_run("zypper mr --enable --all");
    set_var("VIDEOMODE", '');
    # keep the value of SCC_REGISTER for offline migration tests with smt pattern or modules
    # Both of them need registration during offline migration
    if (!(is_smt_or_module_tests || get_var('KEEP_REGISTERED'))) { set_var("SCC_REGISTER", ''); }

    # mark system patched
    set_var("SYSTEM_PATCHED", 1);
}

sub install_package {
    my @pk_list = split(/,/, get_var('PACKAGES'));
    for my $pk (@pk_list) {
        # removed package if starting with -
        if ($pk =~ /^-/) {
            $pk =~ s/^-//;
            zypper_call "rm -t package $pk";
        }
        else {
            zypper_call "in -t package $pk";
        }
    }
}

sub install_patterns {
    my $pcm = 0;
    my @pt_list;
    my @pt_list_un;
    my @pt_list_in = split(/ /, script_output("zypper pt -i | grep '^i' | awk -F '|' '{print \$2}' | sort -u | xargs"));

    # install all patterns from product.
    if (check_var('PATTERNS', 'all')) {
        @pt_list_un = split(/ /, script_output("zypper pt -u | grep '^ ' | awk '{print \$2}' | sort -u | xargs"));
    }
    # install certain pattern from parameter.
    else {
        @pt_list_un = split(/,/, get_var('PATTERNS'));
    }

    my %installed_pt = ();
    foreach (@pt_list_in) {
        $installed_pt{$_} = 1;
    }
    @pt_list = sort grep(!$installed_pt{$_}, @pt_list_un);
    $pcm = grep /Amazon-Web-Services|Google-Cloud-Platform|Microsoft-Azure/, @pt_list_in;

    for my $pt (@pt_list) {
        # Cloud patterns are conflict by each other, only install cloud pattern from single vender.
        if ($pt =~ /Amazon-Web-Services|Google-Cloud-Platform|Microsoft-Azure/) {
            next unless $pcm == 0;
            $pt .= '*';
            $pcm = 1;
        }
        zypper_call "in -t pattern $pt";
    }
}

sub run {
    my ($self) = @_;

    $self->setup_migration();
    $self->patching_sle();
}

sub test_flags {
    return {milestone => 1, fatal => 1};
}

1;
