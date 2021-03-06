# SUSE's openQA tests
#
# Copyright © 2017 SUSE LLC
#
# Copying and distribution of this file, with or without modification,
# are permitted in any medium without royalty provided the copyright
# notice and this notice are preserved.  This file is offered as-is,
# without any warranty.

# Summary: Do basic checks to make sure system is ready for wicked testing
# Maintainer: Anton Smorodskyi <asmorodskyi@suse.com>

use base 'wickedbase';
use strict;
use testapi;
use utils 'systemctl';
use version_utils qw(is_sle sle_version_at_least);

sub run {
    my ($self) = @_;
    select_console('root-console');
    my $enable_command_logging = 'export PROMPT_COMMAND=\'logger -t openQA_CMD "$(history 1 | sed "s/^[ ]*[0-9]\+[ ]*//")"\'';
    assert_script_run("echo \"$enable_command_logging\" >> /root/.bashrc");
    assert_script_run($enable_command_logging);
    type_string("#Preparation for wicked test\n");
    type_string("#* Checking that network is up\n");
    systemctl('is-active network');
    systemctl('is-active wicked');
    assert_script_run('[ -z "$(coredumpctl -1 --no-pager --no-legend)" ]');
    type_string("#* Setting debug level for wicked logs\n");
    assert_script_run('sed -e "s/^WICKED_DEBUG=.*/WICKED_DEBUG=\"all\"/g" -i /etc/sysconfig/network/config');
    assert_script_run('sed -e "s/^WICKED_LOG_LEVEL=.*/WICKED_LOG_LEVEL=\"debug\"/g" -i /etc/sysconfig/network/config');
    assert_script_run('cat /etc/sysconfig/network/config');
    assert_script_run('mkdir /data');
}

sub test_flags {
    return {fatal => 1};
}

1;
