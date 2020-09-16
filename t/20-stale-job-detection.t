#!/usr/bin/env perl

# Copyright (C) 2016-2020 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib";
use DateTime;
use Test::Warnings ':report_warnings';
use Test::Output qw(combined_like stderr_like);
use OpenQA::Constants qw(DEFAULT_WORKER_TIMEOUT DB_TIMESTAMP_ACCURACY);
use OpenQA::Jobs::Constants;
use OpenQA::WebSockets;
use OpenQA::Test::Database;
use OpenQA::Test::Utils qw(setup_mojo_app_with_default_worker_timeout redirect_output);

my $schema = OpenQA::Test::Database->new->create(fixtures_glob => '01-jobs.pl 02-workers.pl 06-job_dependencies.pl');
my $jobs   = $schema->resultset('Jobs');
$jobs->find(99963)->update({assigned_worker_id => 1});
$jobs->find(99961)->update({assigned_worker_id => 2});
$jobs->find(80000)->update({state              => ASSIGNED, result => NONE, assigned_worker_id => 1});

setup_mojo_app_with_default_worker_timeout;

subtest 'worker with job and not updated in last 120s is considered dead' => sub {
    my $dtf     = $schema->storage->datetime_parser;
    my $dt      = DateTime->from_epoch(epoch => time(), time_zone => 'UTC');
    my $workers = $schema->resultset('Workers');
    my $jobs    = $jobs;
    $workers->update_all({t_seen => $dtf->format_datetime($dt)});
    is($jobs->stale_ones->count, 0, 'job not considered stale if recently seen');
    $dt->subtract(seconds => DEFAULT_WORKER_TIMEOUT + DB_TIMESTAMP_ACCURACY);
    $workers->update_all({t_seen => $dtf->format_datetime($dt)});
    is($jobs->stale_ones->count, 3, 'jobs considered stale if t_seen exceeds the timeout');
    $workers->update_all({t_seen => undef});
    is($jobs->stale_ones->count, 3, 'jobs considered stale if t_seen is not set');

    stderr_like { OpenQA::Scheduler::Model::Jobs->singleton->incomplete_and_duplicate_stale_jobs }
    qr/Dead job 99961 aborted and duplicated 99982\n.*Dead job 99963 aborted as incomplete/, 'dead jobs logged';

    for my $job_id (99961, 99963) {
        my $job = $jobs->find(99963);
        is($job->state,  DONE,       "running job $job_id is now done");
        is($job->result, INCOMPLETE, "running job $job_id has been marked as incomplete");
        isnt($job->clone_id, undef, "running job $job_id a clone");
        like(
            $job->reason,
            qr/abandoned: associated worker (remote|local)host:1 has not sent any status updates for too long/,
            "job $job_id set as incomplete"
        );
    }

    my $assigned_job = $jobs->find(80000);
    is($assigned_job->state,              SCHEDULED, 'assigned job not done');
    is($assigned_job->result,             NONE,      'assigned job has been re-scheduled');
    is($assigned_job->clone_id,           undef,     'assigned job has not been cloned');
    is($assigned_job->assigned_worker_id, undef,     'assigned job has no worker assigned');
};

subtest 'exception during stale job detection handled and logged' => sub {
    my $mock_schema = Test::MockModule->new('OpenQA::Schema');
    my $mock_singleton_called;
    $mock_schema->redefine(singleton => sub { $mock_singleton_called++; bless({}); });
    combined_like { OpenQA::Scheduler::Model::Jobs->singleton->incomplete_and_duplicate_stale_jobs }
    qr/Failed stale job detection/, 'failure logged';
    ok($mock_singleton_called, 'mocked singleton method has been called');
};

done_testing();

1;
