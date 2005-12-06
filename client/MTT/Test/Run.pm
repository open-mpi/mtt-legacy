#!/usr/bin/env perl
#
# Copyright (c) 2004-2005 The Trustees of Indiana University.
#                         All rights reserved.
# Copyright (c) 2004-2005 The Trustees of the University of Tennessee.
#                         All rights reserved.
# Copyright (c) 2004-2005 High Performance Computing Center Stuttgart, 
#                         University of Stuttgart.  All rights reserved.
# Copyright (c) 2004-2005 The Regents of the University of California.
#                         All rights reserved.
# $COPYRIGHT$
# 
# Additional copyrights may follow
# 
# $HEADER$
#

package MTT::Test::Run;

use strict;
use Cwd;
use File::Basename;
use MTT::Messages;
use MTT::Values;
use Data::Dumper;

#--------------------------------------------------------------------------

# Exported current number of processes in the test
our $test_np;

# Exported current executable under text
our $test_executable;

# Exported current argv under test
our $test_argv;

# Exported exit status of the last test run
our $test_exit_status;

#--------------------------------------------------------------------------

sub Run {
    my ($ini, $build_dir, $force) = @_;

    # Save the environment
    my %ENV_SAVE = %ENV;

    Verbose("*** Run test phase starting\n");

    # We want to run through every test build and run it with its
    # target MPI.
    # For each MPI source
    foreach my $mpi_section_key (keys(%{$MTT::Test::builds})) {
        my $mpi_section = $MTT::Test::builds->{$mpi_section_key};

        # For each instance of that source
        foreach my $mpi_unique_key (keys(%{$mpi_section})) {
            my $mpi_unique = $mpi_section->{$mpi_unique_key};

            # For each install of that source
            foreach my $install_section_key (keys(%{$mpi_unique})) {
                my $install_section = $mpi_unique->{$install_section_key};

                # For each test build
                foreach my $test_build_key (keys(%{$install_section})) {
                    my $test_build = $install_section->{$test_build_key};
                    $test_build->{section_name} =~ m/test build:\s*(.+)\s*/;
                    my $test_name = $1;

                    # Now that we've got a single test build, run
                    # through the INI file and find all "test run:"
                    # section that have a "test" attribute that
                    # matches this test build's section name.

                    foreach my $section ($ini->Sections()) {
                        if ($section =~ /^\s*test run:/) {
                            my $target_test = 
                                MTT::Values::Value($ini, $section, "test");

                            if ($target_test eq $test_name) {
                                Debug("Found a match! $target_test [$section]\n");
                                my $mpi_install = $MTT::MPI::installs->{$mpi_section_key}->{$mpi_unique_key}->{$install_section_key};

                                _do_run($ini, $section, $test_build, 
                                        $mpi_install);
                                %ENV = %ENV_SAVE;
                            }
                        }
                    }                        
                }
            }
        }
    }

    Verbose("*** Run test phase complete\n");
} 

#--------------------------------------------------------------------------

sub _do_run {
    my ($ini, $section, $test_build, $mpi_install) = @_;

    # Check for the module
    my $module = MTT::Values::Value($ini, $section, "module");
    if (!$module) {
        Warning("No module specified in [$section]; skipping\n");
        return;
    }

    # Find an MPI details section for this MPI
    my $match = 0;
    my $mpi_details_section;
    foreach my $s ($ini->Sections()) {
        if ($s =~ /^\s*mpi details:/) {
            my $section_mpi_name = MTT::Values::Value($ini, $s, "mpi_name");
            if ($section_mpi_name eq $mpi_install->{mpi_name}) {
                Debug("Found MPI details\n");
                $match = 1;
                $mpi_details_section = $s;
                last;
            }
        }
    }
    if (!$match) {
        Warning("Unable to find MPI details section; skipping\n");
        return;
    }
    
    # Get some details about running with this MPI
    my $mpi_details;
    $mpi_details->{before_any_exec} = 
        MTT::Values::Value($ini, $mpi_details_section, "before_any_exec");
    $mpi_details->{before_each_exec} = 
        MTT::Values::Value($ini, $mpi_details_section, "before_each_exec");
    $mpi_details->{after_each_exec} = 
        MTT::Values::Value($ini, $mpi_details_section, "after_each_exec");
    $mpi_details->{after_all_exec} = 
        MTT::Values::Value($ini, $mpi_details_section, "after_all_exec");
    # Do not evaluate this one now yet
    my $exec = $ini->val($mpi_details_section, "exec");
    while ($exec =~ m/@(.+?)@/) {
        my $val = $ini->val($mpi_details_section, $1);
        if (!$val) {
            Warning("Used undefined key @$1@ in exec value; skipping");
            return;
        }
        $exec =~ s/@(.+?)@/$val/;
    }
    Debug("Got final exec: $exec\n");
    $mpi_details->{exec} = $exec;

    # Go to the right dir
    chdir($test_build->{srcdir});

    # Set the PATH and LD_LIBRARY_PATH
    if ($mpi_install->{bindir}) {
        if (exists($ENV{PATH})) {
            $ENV{PATH} = "$mpi_install->{bindir}:" . $ENV{PATH};
        } else {
            $ENV{PATH} = $mpi_install->{bindir};
        }
    }
    if ($mpi_install->{libdir}) {
        if (exists($ENV{LD_LIBRARY_PATH})) {
            $ENV{LD_LIBRARY_PATH} = "$mpi_install->{libdir}:" . $ENV{LD_LIBRARY_PATH};
        } else {
            $ENV{LD_LIBRARY_PATH} = $mpi_install->{libdir};
        }
    }

    # Process setenv, unsetenv, prepend-path, and append-path -- for
    # both the MPI that we're building with and the section of the ini
    # file that we're building.
    my @save_env;
    MTT::Values::ProcessEnvKeys($mpi_install, \@save_env);
    my $config;
    $config->{setenv} = MTT::Values::Value($ini, $section, "setenv");
    $config->{unsetenv} = MTT::Values::Value($ini, $section, "unsetenv");
    $config->{prepend_path} = MTT::Values::Value($ini, $section, "prepend_path");
    $config->{append_path} = MTT::Values::Value($ini, $section, "append_path");
    MTT::Values::ProcessEnvKeys($config, \@save_env);

    # Get global values that apply to each test executable, unless
    # they supplied their own.  Don't use Value for all of them; some
    # we need to delay the evaluation.
    $config->{np} = $ini->val($section, "np");
    $config->{np} = "1"
        if (!$config->{np});
    $config->{np_ok} = $ini->val($section, "np_ok");
    $config->{np_ok} = "1"
        if (!$config->{np_ok});
    $config->{argv} = $ini->val($section, "argv");
    $config->{argv} = ""
        if (!$config->{argv});
    $config->{pass} = $ini->val($section, "pass");
    $config->{pass} = "&eq(&test_exit_status(), 0)"
        if (!$config->{pass});
    $config->{save_stdout} = $ini->val($section, "save_stdout");
    $config->{save_stdout} = "0"
        if (!$config->{save_stdout});
    $config->{timeout} = $ini->val($section, "timeout");
    $config->{timeout} = "30"
        if (!$config->{timeout});

    # Run the module to get a list of tests to run
    my $ret = MTT::Module::Run("MTT::Test::Run::$module",
                               "Run", $ini, $section, $test_build,
                               $mpi_install, $config);

    # Analyze the return -- should give us a list of tests to run
    if ($ret && $ret->{success}) {

        # Loop through all the tests
        foreach my $test (@{$ret->{tests}}) {
            if (!exists($test->{executable})) {
                Warning("No executable specified for text; skipped\n");
                next;
            }

            # Get the values for this test
            my $run;
            $run->{executable} = $test->{executable};
            foreach my $key (qw(np np_ok argv pass save_stdout timeout)) {
                my $str = "\$run->{$key} = exists(\$test->{$key}) ? \$test->{$key} : \$config->{$key}";
                eval $str;
            }

            # Setup some globals
            $test_executable = $run->{executable};
            $test_argv = $run->{argv};
            my $all_np = MTT::Values::EvaluateString($run->{np});

            # Just one np, or an array of np values?
            if (ref($all_np) eq "") {
                _run_one_np($run, $mpi_details, $all_np);
            } else {
                foreach my $this_np (@$all_np) {
                    _run_one_np($run, $mpi_details, $all_np);
                }
            }
        }

        # If we ran any tests at all, then run the after_all setp
        if (exists($mpi_details->{ran_some_tests})) {
            _run_step($mpi_details, "after_all");
        }
    }
}

sub _run_one_np {
    my ($run, $mpi_details, $np) = @_;

    my $name = basename($test_executable);

    # Load up the final global
    $test_np = $np;

    # Is this np ok for this test?
    my $ok = MTT::Values::EvaluateString($run->{np_ok});
    if ($ok) {

        # Yes, it is.  See if we need to run the before_all step.
        if (! exists($mpi_details->{before_any_ran})) {
            _run_step($mpi_details, "before_any");
        }
        $mpi_details->{ran_some_tests} = 1;

        # Get all the exec's for this one np
        my $execs = MTT::Values::EvaluateString($mpi_details->{exec});

        # If we just got one, run it.  Otherwise, loop over running them.
        if (ref($execs) eq "") {
            _run_one_test($run, $mpi_details, $execs, $name);
        } else {
            foreach my $e (@$execs) {
                _run_one_test($run, $mpi_details, $e, $name);
            }
        }
    }
}

sub _run_one_test {
    my ($run, $mpi_details, $cmd, $name) = @_;

    # If there is a before_each step, run it
    _run_step($mpi_details, "before_each");

    my $timeout = MTT::Values::EvaluateString($run->{timeout});
    my $x = MTT::DoCommand::Cmd(1, $cmd, $timeout);
    $test_exit_status = $x->{status};
    my $pass = MTT::Values::EvaluateString($run->{pass});
    if (!$pass) {
        Warning("Test failed: $name\n");
    } else {
        Verbose("Test passed: $name\n");
    }

    # If there is an after_each step, run it
    _run_step($mpi_details, "after_each");

    return $pass;
}

sub _run_step {
    my ($mpi_details, $step) = @_;

    $step .= "_exec";
    if (exists($mpi_details->{$step})) {
        my $x = MTT::DoCommand::Cmd(1, $mpi_details->{$step}, 10);
    }
}

1;