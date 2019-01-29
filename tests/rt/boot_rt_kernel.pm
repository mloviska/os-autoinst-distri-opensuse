# SUSE's openQA tests
#
# Copyright Â© 2009-2013 Bernhard M. Wiedemann
# Copyright Â© 2012-2019 SUSE LLC
#
# Copying and distribution of this file, with or without modification,
# are permitted in any medium without royalty provided the copyright
# notice and this notice are preserved.  This file is offered as-is,
# without any warranty.

use base 'opensusebasetest';
use strict;
use y2logsstep;
use testapi;
use utils;
use rt_utils 'select_kernel';

sub run() {
    my ($self) = @_;
    my $kernel = get_var('KERNEL_TO_BOOT');

    rt_utils::select_kernel("$kernel");
}

1;

# vim: set sw=4 et:
