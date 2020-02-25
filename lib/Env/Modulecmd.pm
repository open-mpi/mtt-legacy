# $Id: Modulecmd.pm,v 4.1 2004/05/07 15:42:15 ronisaac Exp $

# Copyright (c) 2001-2004, Morgan Stanley Dean Witter and Co.
# Distributed under the terms of the GNU General Public License.
# Please see the copyright notice at the end of this file for more information.

package Env::Modulecmd;

BEGIN {
  # defaults: if Env::Modulecmd is built using perl5.005 or later, the
  # magic strings below are replaced with values supplied to 'make' at
  # build time

  my $modulecmd  = '@@DEFAULT_PERL_MODULECMD@@';
  my $modulepath = '@@DEFAULT_MODULEPATH@@';

  $ENV{PERL_MODULECMD} ||= $modulecmd  unless ($modulecmd  =~ /^\@\@/);
  $ENV{MODULEPATH}     ||= $modulepath unless ($modulepath =~ /^\@\@/);
}

use strict;
use Carp;
use vars qw($VERSION $AUTOLOAD);

use IPC::Open3;
use IO::Handle;

$VERSION = 1.2;

# Look for modulecmd
my $modulecmd;
if (-x "$ENV{PERL_MODULECMD}") {
    $modulecmd = "$ENV{PERL_MODULECMD}";
} elsif (-x "$ENV{MODULESHOME}$ENV{MODULE_VERSION}/bin/modulecmd") {
    $modulecmd = "$ENV{MODULESHOME}$ENV{MODULE_VERSION}/bin/modulecmd";
} elsif (-x "$ENV{MODULESHOME}/bin/modulecmd") {
    $modulecmd = "$ENV{MODULESHOME}/bin/modulecmd";
} else {
    $modulecmd = "modulecmd";
}

sub import {
  my @args = @_;
  shift @args;

  # import just dispatches commands to _modulecmd

  foreach my $arg (@args) {
    if (ref ($arg) eq "HASH") {
      my %hash = %{$arg};
      foreach my $key (keys %hash) {
        my $val = $hash{$key};
        if (ref ($val) eq "ARRAY") {
          _modulecmd ($key, $_) for @{$val};
        } else {
          _modulecmd ($key, $val);
        }
      }
    } else {
      _modulecmd ('load', $arg);
    }
  }
}

sub AUTOLOAD {
  my @modules = @_;

  # AUTOLOAD, like import, calls _modulecmd with the requested function

  my $fun = $AUTOLOAD;
  $fun =~ s/^.*:://;

  _modulecmd ($fun, $_) for @modules;
}

sub _indent {
  my ($str) = @_;

  $str =~ s/\n$//;
  $str =~ s/\n/\n -> /g;
  $str = " -> $str\n";

  return ($str);
}

sub _modulecmd {
  my ($fun, $module) = @_;

  # here's where the actual work gets done. first we build a command
  # string and send it to open3 for execution. we're not sending any
  # input, but we want to catch both its standard output and standard
  # error, so a simple piped open won't work.

  my @cmd = ($modulecmd, "perl", $fun, $module);
  my $cmd = join (" ", @cmd);

  my $pid = 0;
  my $out = '';
  my $err = '';

  {
    # need to turn off all warnings here, or else we get a double
    # error from open3 if the exec fails

    local $^W = 0;

    my $IN  = IO::Handle->new;
    my $OUT = IO::Handle->new;
    my $ERR = IO::Handle->new;

    $pid = open3 ($IN, $OUT, $ERR, @cmd);

    # slurp all output

    undef local $/;

    $out = <$OUT>;
    $err = <$ERR>;
  }

  waitpid ($pid, 0);
  my $retcode = $? >> 8;

  # if the process sent anything to standard error, or if it exited
  # with a non-zero return code, it may have "failed"

  if ($err || $retcode) {
    my $croak = 0;

    # attempt to guess whether the stderr output is a real error
    # generated by modulecmd, or just an informational message output
    # by the module itself. error messages from modulecmd (like
    # "Couldn't find modulefile ... in MODULEPATH") fall into two
    # categories: they either (a) start with "ERROR:", or (b) start
    # and end with a row of dashes, and contain the message shown
    # below. (note that "occurred" is misspelled as "occured" in the
    # modulecmd source.)

    my $error_from_modulecmd =
      (($err =~ /^ERROR:/) or
       ($err =~ /^-----/ and $err =~ /-----\s*$/ and
        $err =~ /An error occur*ed while processing your module command/));

    $croak = 1
      if $error_from_modulecmd;

    # now check for an exec failure. open3 obviously doesn't attempt
    # to exec modulecmd until after it forks; if the exec fails, it
    # croaks from the child process. we could check the STDERR output
    # for "open3: exec of ... failed", except that on win32, the exec
    # NEVER fails. (this is because exec's on win32 are done via
    # system(), which uses cmd.exe, and the running cmd.exe always
    # succeeds, leaving the child process to print an error message,
    # with no indication whether the error came from cmd.exe or from
    # modulecmd itself.)
    #
    # a non-zero return code is the best way to detect an exec
    # failure, and modulecmd itself will hardly ever exit with a
    # non-zero return code. however, there are two cases where it
    # will: (a) invalid syntax, like "modulecmd no-such-shell list";
    # and (b) "modulecmd perl load /no/such/directory". in these
    # cases, we attempt to determine, using the pattern above, whether
    # this is an error message from modulecmd. if not, we assume it's
    # a message about a failure to exec modulecmd in the first place.

    if ($retcode) {
      $croak = 1;

      unless ($error_from_modulecmd) {

        # if we're on win32, we'll actually get a semi-useful error
        # message from cmd.exe, such as "The system cannot find the
        # path specified." on unix, it's just "open3: exec of ...
        # failed at Modulecmd.pm line 123"; there's no detailed
        # reason, and the line number in Modulecmd.pm doesn't help
        # anybody. so if the error output begins with "open3:", we
        # assume that it's useless and build our own message.

        croak "Unable to execute '$cmd'" .
          ($err =~ /^open3:/ ? "\n" : ":\n" . _indent ($err)) .
          "Error loading module $module";
      }
    }

    # now, if $croak is set, it's a fatal error, so croak on it.
    # otherwise, issue a warning, but only if -w is in effect.

    if ($croak) {
      croak
        ("Errors from '$cmd':\n" .
         _indent ($err) .
         "Error loading module $module");
    } else {
      carp
        ("Messages from '$cmd':\n" .
         _indent ($err) .
         "Possible error loading module $module")
          if $^W;
    }
  }

  # if we got here, then the command didn't fail. if it did generate
  # output, then we have something to eval.

  if ($out) {

    # what if we try to eval something that's not valid perl? in this
    # case, eval will die, with a message indicating what went wrong.
    # we want to catch this and nicely print out the error.

    # $_mlstatus is a variable dumped by modulecmd without 'my'.
    # See https://github.com/cea-hpc/modules/pull/314 for details.
    my $_mlstatus = 0;
    eval $out;

    croak
      ("'$cmd' generated output:\n" .
       _indent ($out) .
       "Error evaluating:\n" .
       _indent ($@) .
       "Error loading module $module")
        if $@;
  }
}

1;

__END__

=head1 NAME

Env::Modulecmd - Interface to modulecmd from Perl

=head1 SYNOPSIS

  # import bootstraps, executed at compile-time

    # explicit operations

    use Env::Modulecmd { load => 'foo/1.0',
                         unload => ['bar/1.0', 'baz/1.0'],
                       };

    # implied loading

    use Env::Modulecmd qw(quux/1.0 quuux/1.0);

    # hybrid

    use Env::Modulecmd ('bazola/1.0', 'ztesch/1.0',
                        { load => 'oogle/1.0',
                          unload => [qw(foogle/1.0 boogle/1.0)],
                        }
                       );

  # implicit functions, executed at run-time

    Env::Modulecmd::load (qw(fred/1.0 jim/1.0 sheila/barney/1.0));
    Env::Modulecmd::unload ('corge/grault/1.0', 'flarp/1.0');
    Env::Modulecmd::pippo ('pluto/paperino/1.0');

=head1 DESCRIPTION

C<Env::Modulecmd> provides an automated interface to C<modulecmd> from
Perl. The most straightforward use of Env::Modulecmd is for loading
and unloading modules at compile time, although many other uses are
provided.

=head2 modulecmd Interface

In general, C<Env::Modulecmd> works by making a system call to
'C<modulecmd perl [cmd] [module]>', under the assumption that
C<modulecmd> is in your PATH. If you set the environment variable
C<PERL_MODULECMD>, C<Env::Modulecmd> will use that value in place of
C<modulecmd>. If C<modulecmd> is not found, the shell will return an
error and the script will die.

I<Note: a default path to C<modulecmd>, and a default setting for
C<MODULEPATH>, can be built into C<Env::Modulecmd> when it's
installed. See the C<README> file in the source tree for more
information.>

Modules may, by convention, output warnings and informational
messages; C<modulecmd> directs these to standard error. If
C<modulecmd> outputs anything to standard error, C<Env::Modulecmd>
inspects that output and attempts to determine whether it represents a
fatal error. If the output begins with "ERROR:", or if it matches
C<modulecmd>'s typical error message format, C<Env::Modulecmd> fails.
Otherwise, C<Env::Modulecmd> emits that output as a warning, but only
if Perl warnings are enabled (C<-w>, or C<use warnings>).

If there were no fatal errors, C<modulecmd>'s output (if any) is
C<eval>'ed. If the C<eval> operation fails, C<Env::Modulecmd> will
fail.

If you attempt to load a module which has already been loaded, or
perform some other benign operation, C<modulecmd> will generate
neither output nor error; this condition is silently ignored.

=head2 Compile-Time Usage

You can specify compile-time arguments to C<Env::Modulecmd> on the
C<use> line, as follows:

  use Env::Modulecmd ('bazola/1.0', 'ztesch/1.0',
                      { load => 'oogle/1.0',
                        unload => [qw(foogle/1.0 boogle/1.0)],
                      }
                     );

Each argument is assumed to be either a scalar or a hashref. If it's a
scalar, C<Env::Modulecmd> assumes it's the name of a module you want
to load. If it's a hashref, then each key is the name of a modulecmd
operation (ie: C<load>, C<unload>) and each value is either a scalar
(operate on one module) or an arrayref (operate on several modules).

In the example given above, C<bazola/1.0> and C<ztesch/1.0> will be
loaded by implicit usage. C<oogle/1.0> will be loaded explicitly, and
C<foogle/1.0> and C<boogle/1.0> will be unloaded.

=head2 Run-Time Usage

Additional module operations can be performed at run-time by using
implicit functions. For example:

  Env::Modulecmd::load (qw(fred/1.0 jim/1.0 sheila/barney/1.0));
  Env::Modulecmd::unload ('corge/grault/1.0', 'flarp/1.0');
  Env::Modulecmd::pippo ('pluto/paperino/1.0');

Each function name is passed as a command name to C<modulecmd>, and
each call can include one or more modules to be processed. The example
above will generate the following six calls to C<modulecmd>:

  modulecmd perl load fred/1.0
  modulecmd perl load jim/1.0
  modulecmd perl load sheila/barney/1.0
  modulecmd perl unload corge/grault/1.0
  modulecmd perl unload flarp/1.0
  modulecmd perl pippo pluto/paperino/1.0

=head1 SEE ALSO

For more information about modules, see the F<module(1)> manpage or
F<http://www.modules.org>.

=head1 BUGS

If you find any bugs, or if you have any suggestions for improvement,
please contact the author.

=head1 AUTHOR

Ron Isaacson <F<Ron.Isaacson@morganstanley.com>>

=head1 COPYRIGHT

Copyright (c) 2001-2004, Morgan Stanley Dean Witter and Co.

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or (at
your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
General Public License for more details.

A copy of the GNU General Public License was distributed with this
program in a file called LICENSE. For additional copies, write to the
Free Software Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
02111-1307, USA.

=cut
