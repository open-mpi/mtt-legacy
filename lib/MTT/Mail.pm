#!/usr/bin/env perl
#
# Copyright (c) 2005-2006 The Trustees of Indiana University.
#                         All rights reserved.
# $COPYRIGHT$
# 
# Additional copyrights may follow
# 
# $HEADER$
#

package MTT::Mail;

use strict;
use POSIX qw(strftime);
use MTT::Messages;
use MTT::FindProgram;
use Data::Dumper;

#--------------------------------------------------------------------------

# have we initialized?
my $initialized;

# my mail program
my $mail_agent;

# cache a copy of the environment
my %ENV_original;

#--------------------------------------------------------------------------

sub Init {

    # Find a mail agent

    $mail_agent = FindProgram(qw(Mail mailx mail));
    if (!defined($mail_agent)) {
        Warning("Could not find a mail agent for MTT::Mail");
        return undef;
    }

    # Save a copy of the environment; we use this later

    %ENV_original = %ENV;

    Debug("Mail agent initialized\n");

    $initialized = 1;
}

#--------------------------------------------------------------------------

sub Send {
    my ($subject, $to, $body) = @_;

    Init()
        if (! $initialized);

    # Use our "good" environment (e.g., one with TMPDIR set properly)

    my %ENV_now = %ENV;
    %ENV = %ENV_original;

    # Invoke the mail agent to send the mail

    open MAIL, "|$mail_agent -s \"$subject\" \"$to\"" ||
        die "Could not open pipe to output e-mail\n";
    print MAIL "$body\n";
    close MAIL;

    # Restore the old environment

    %ENV = %ENV_now;
}

1;