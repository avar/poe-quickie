package POE::Quickie;

use strict;
use warnings;
use Carp 'croak';
use POE;
use POE::Wheel::Run;

require Exporter;
use base 'Exporter';
our @EXPORT      = qw(quickie quickie_merged quickie_tee quickie_tee_merged);
our @EXPORT_OK   = @EXPORT;
our %EXPORT_TAGS = (ALL => [@EXPORT]);

our %OBJECTS;

sub new {
    my ($package, %args) = @_;

    my $parent_id = $poe_kernel->get_active_session->ID;
    if (my $self = $OBJECTS{$parent_id}) {
        return $self;
    }

    my $self = bless \%args, $package;
    $self->{parent_id} = $parent_id;
    $OBJECTS{$parent_id} = $self;

    return $self;
}

sub _create_session {
    my ($self) = @_;

    POE::Session->create(
        object_states => [
            $self => [qw(
                _start
                _stop
                _exception
                _create_wheel
                _delete_wheel
                _child_signal
                _child_closed
                _child_timeout
                _child_stdout
                _child_stderr
                _killall
            )],
        ],
        options => {
            ($self->{debug}   ? (debug   => 1) : ()),
            ($self->{default} ? (default => 1) : ()),
            ($self->{trace}   ? (trace   => 1) : ()),
        },
    );

    $self->{got_session} = 1;

    return;
}

sub _start {
    my ($kernel, $session, $self) = @_[KERNEL, SESSION, OBJECT];

    my $session_id = $session->ID;
    $self->{session_id} = $session_id;
    $kernel->sig(DIE => '_exception');
    return;
}

sub _stop {
    my $self = $_[OBJECT];
    $self->{got_session} = 0;
    return;
}

sub run {
    my ($self, %args) = @_;

    croak 'Program parameter not supplied' if !defined $args{Program};

    if ($args{AltFork} && ref $args{Program}) {
        croak 'Program must be a string when AltFork is enabled';
    }

    if ($args{AltFork} && $^O eq 'Win32') {
        croak 'AltFork does not currently work on Win32';
    }

    $self->_create_session() if !$self->{got_session};

    my ($exception, $wheel)
        = $poe_kernel->call($self->{session_id}, '_create_wheel', \%args);

    # propagate possible exception from POE::Wheel::Run->new()
    croak $exception if $exception;

    return $wheel->PID;
}

sub _create_wheel {
    my ($kernel, $self, $args) = @_[KERNEL, OBJECT, ARG0];

    my $program = $args->{Program};
    if ($args->{AltFork}) {
        my @inc = map { +'-I' => $_ } @INC;
        $program = [$^X, @inc, '-e', $program];
    }

    my $wheel;
    eval {
        $wheel = POE::Wheel::Run->new(
            CloseEvent  => '_child_closed',
            StdoutEvent => '_child_stdout',
            StderrEvent => '_child_stderr',
            Program     => $program,
            (defined $args->{ProgramArgs}
                ? (ProgramArgs => $args->{ProgramArgs})
                : ()
            ),
            (ref $args->{Program} eq 'CODE' && $^O eq 'Win32'
                ? (CloseOnCall => 1)
                : ()
            ),
            (defined $args->{WheelArgs}
                ? (%{ $args->{WheelArgs} })
                : ()
            ),
        );
    };

    if ($@) {
        chomp $@;
        return $@;
    }

    $self->{wheels}{$wheel->ID}{obj} = $wheel;
    $self->{wheels}{$wheel->ID}{args} = $args;
    $self->{wheels}{$wheel->ID}{alive} = 2;

    if (defined $args->{Timeout}) {
        $self->{wheels}{$wheel->ID}{alrm}
            = $kernel->delay_set('_child_timeout', $args->{Timeout}, $wheel->ID);
    }
    $kernel->sig_child($wheel->PID, '_child_signal');

    return (undef, $wheel);
}

sub _exception {
    my ($kernel, $self, $ex) = @_[KERNEL, OBJECT, ARG1];
    chomp $ex->{error_str};
    warn "Event $ex->{event} in session "
        .$ex->{dest_session}->ID." raised exception:\n  $ex->{error_str}\n";
    $kernel->sig_handled();
    return;
}

sub _child_signal {
    my ($kernel, $self, $pid, $status) = @_[KERNEL, OBJECT, ARG1, ARG2];
    my $id = $self->_pid_to_id($pid);
    $self->{wheels}{$id}{status} = $status;
    $self->{lazy}{$pid}{status} = $status if $self->{lazy}{$pid};
    $kernel->yield('_delete_wheel', $id);
    return;
}

sub _child_closed {
    my ($kernel, $self, $id) = @_[KERNEL, OBJECT, ARG0];
    $kernel->yield('_delete_wheel', $id);
    return;
}

sub _child_timeout {
    my ($self, $id) = @_[OBJECT, ARG0];
    $self->{wheels}{$id}{obj}->kill();
    return;
}

sub _child_stdout {
    my ($kernel, $self, $output, $id) = @_[KERNEL, OBJECT, ARG0, ARG1];

    my $pid = $self->{wheels}{$id}{obj}->PID;

    if ($self->{lazy}{$pid}) {
        if ($self->{lazy}{$pid}{Merged}) {
            push @{ $self->{lazy}{$pid}{merged} }, $output;
        }
        else {
            push @{ $self->{lazy}{$pid}{stdout} }, $output;
        }

        if ($self->{lazy}{$pid}{Tee}) {
            print $output, "\n";
        }
    }
    elsif (!exists $self->{wheels}{$id}{args}{StdoutEvent}) {
        print "$output\n";
    }
    elsif (defined (my $event = $self->{wheels}{$id}{args}{StdoutEvent})) {
        my $context = $self->{wheels}{$id}{args}{Context};
        $kernel->post(
            $self->{parent_id},
            $event,
            $output,
            $pid,
            (defined $context ? $context : ()),
        );
    }

    return;
}

sub _child_stderr {
    my ($kernel, $self, $error, $id) = @_[KERNEL, OBJECT, ARG0, ARG1];

    my $pid = $self->{wheels}{$id}{obj}->PID;

    if ($self->{lazy}{$pid}) {
        if ($self->{lazy}{$pid}{Merged}) {
            push @{ $self->{lazy}{$pid}{merged} }, $error;
        }
        else {
            push @{ $self->{lazy}{$pid}{stderr} }, $error;
        }

        if ($self->{lazy}{$pid}{Tee}) {
            $self->{lazy}{$pid}{Merged}
                ? print $error, "\n"
                : warn $error, "\n";
        }
    }
    elsif (!exists $self->{wheels}{$id}{args}{StderrEvent}) {
        warn "$error\n";
    }
    elsif (defined (my $event = $self->{wheels}{$id}{args}{StderrEvent})) {
        my $context = $self->{wheels}{$id}{args}{Context};
        $kernel->post(
            $self->{parent_id},
            $event,
            $error,
            $pid,
            (defined $context ? $context : ()),
        );
    }

    return;
}

# only delete the wheel after both child_signal and child_closed
# have called this
sub _delete_wheel {
    my ($kernel, $self, $id) = @_[KERNEL, OBJECT, ARG0];

    $self->{wheels}{$id}{alive}--;
    return if $self->{wheels}{$id}{alive};

    my $pid = $self->{wheels}{$id}{obj}->PID;
    my $status = $self->{wheels}{$id}{status};
    my $s = $status >> 8;
    if ($s != 0 && !exists $self->{wheels}{$id}{args}{ExitEvent}) {
        warn "Child $pid exited with status $s\n";
    }

    my $event   = $self->{wheels}{$id}{args}{ExitEvent};
    my $context = $self->{wheels}{$id}{args}{Context};

    $kernel->alarm_remove($self->{wheels}{$id}{alrm});
    delete $self->{wheels}{$id};

    if (defined $event) {
        $kernel->post(
            $self->{parent_id},
            $event,
            $status,
            $pid,
            (defined $context ? $context : ()),
        );
    }

    return;
}

sub _pid_to_id {
    my ($self, $pid) = @_;

    for my $id (keys %{ $self->{wheels} }) {
        return $id if $self->{wheels}{$id}{obj}->PID == $pid;
    }

    return;
}

sub killall {
    my ($self) = @_;
    $poe_kernel->call($self->{session_id}, '_killall');
    return;
}

sub _killall {
    my ($kernel, $self) = @_[KERNEL, OBJECT];

    $kernel->alarm_remove_all();

    for my $id (keys %{ $self->{wheels}}) {
        $self->{wheels}{$id}{obj}->kill();
    }

    return;
}

sub programs {
    my ($self) = @_;

    my %wheels;
    for my $id (keys %{ $self->{wheels} }) {
        my $pid = $self->{wheels}{$id}{obj}->PID;
        $wheels{$pid} = $self->{wheels}{$id}{args}{Context};
    }

    return \%wheels;
}

sub _lazy_run {
    my ($self, %args) = @_;

    $self->_create_session() if !$self->{got_session};
    my $parent_id = $poe_kernel->get_active_session->ID;
    $poe_kernel->refcount_increment($parent_id, __PACKAGE__);
    $poe_kernel->refcount_increment($self->{session_id}, __PACKAGE__);

    my $run_args = delete $args{RunArgs};
    if (@$run_args == 1 &&
        (!ref $run_args->[0] || ref($run_args->[0]) =~ /^(?:ARRAY|CODE)$/)) {
        $run_args = [Program => $run_args->[0]];
    }

    my $pid = $self->run(
        @$run_args,
        ExitEvent => undef,
        ($args{Tee} ? () : (StderrEvent => undef)),
        ($args{Tee} ? () : (StdoutEvent => undef)),
    );

    my $id = $self->_pid_to_id($pid);
    $self->{lazy}{$pid} = { %args };
    $poe_kernel->run_one_timeslice() while $self->{wheels}{$id};

    my $result = delete $self->{lazy}{$pid};
    my $stdout = join '', map { "$_\n" } @{ $result->{stdout} || [] };
    my $stderr = join '', map { "$_\n" } @{ $result->{stderr} || [] };
    my $merged = join '', map { "$_\n" } @{ $result->{merged} || [] };
    my $status = $result->{status};

    $poe_kernel->refcount_decrement($parent_id, __PACKAGE__);
    $poe_kernel->refcount_decrement($self->{session_id}, __PACKAGE__);

    return $merged, $status if $args{Merged};
    return $stdout, $stderr, $status;
}

sub quickie {
    my @args = @_;
    my $self = POE::Quickie->new();

    return $self->_lazy_run(
        RunArgs => \@args
    );
}

sub quickie_tee {
    my @args = @_;
    my $self = POE::Quickie->new();
    return $self->_lazy_run(
        RunArgs => \@args,
        Tee     => 1,
    );
}

sub quickie_merged {
    my @args = @_;
    my $self = POE::Quickie->new();

    return $self->_lazy_run(
        RunArgs => \@args,
        Merged  => 1,
    );
}

sub quickie_tee_merged {
    my @args = @_;
    my $self = POE::Quickie->new();

    return $self->_lazy_run(
        RunArgs => \@args,
        Tee     => 1,
        Merged  => 1,
    );
}

1;

=encoding utf8

=head1 NAME

POE::Quickie - A lazy way to wrap blocking programs

=head1 SYNOPSIS

 use POE::Quickie;

 sub handler {
     my $heap = $_[HEAP];

     # the really lazy interface
     my ($stdout, $stderr, $exit_status) = quickie('foo.pl');
     print $stdout;

     # the more involved interface
     $heap->{quickie} = POE::Quickie->new();
     $heap->{quickie}->run(
         Program     => ['foo.pl', 'bar'],
         StdoutEvent => 'stdout',
         Context     => 'remember this',
     );
 }

 sub stdout {
     my ($output, $context) = @_[ARG0, ARG1];
     print "got output: '$output' in the context of '$context'\n";
 }

=head1 DESCRIPTION

If you need nonblocking access to an external program, or want to execute
some blocking code in a separate process, but you don't want to write a
wrapper module or some L<POE::Wheel::Run|POE::Wheel::Run> boilerplate code,
then POE::Quickie can help. You just specify what you're interested in
(stdout, stderr, and/or exit code), and POE::Quickie will handle the rest in
a sensible way.

It has some convenience features, such as killing processes after a timeout,
and storing process-specific context information which will be delivered with
every event.

There is also an even lazier API which suspends the execution of your event
handler and gives control back to POE while your task is running, the same
way L<LWP::UserAgent::POE|LWP::UserAgent::POE> does. This is provided by the
L<C<quickie_*>|/FUNCTIONS> functions which are exported by default.

=head1 METHODS

=head2 C<new>

Constructs a POE::Quickie object. You'll want to hold on to it.

Takes 3 optional parameters: B<'debug'>, B<'default'>, and B<'trace'>. These
will be passed to the object's L<POE::Session|POE::Session> constructor. See
its documentation for details.

=head2 C<run>

This method starts a new program. It returns the process id of the newly
executed program.

You can either call it with a single argument (string, arrayref, or coderef),
which will used as the B<'Program'> argument, or you can supply the following
key-value pairs:

B<'Program'> (required), will be passed to POE::Wheel::Run's constructor.

B<'AltFork'> (optional), if true, a new instance of the active Perl
interpreter (C<$^X>) will be launched with B<'Program'> (which must be a
string) as the code (I<-e>) argument, and the current C<@INC> passed as
include (I<-I>) arguments. Default is false.

B<'ProgramArgs'> (optional), same as the epynomous parameter to
POE::Wheel::Run.

B<'StdoutEvent'> (optional), the event for delivering lines from the
program's STDOUT. If you don't supply this, they will be printed to the main
program's STDOUT. To explicitly ignore them, set this to C<undef>.

B<'StderrEvent'> (optional), the event for delivering lines from the
program's STDERR. If you don't supply this, they will be printed to the main
program's STDERR. To explicitly ignore them, set this to C<undef>.

B<'ExitEvent'> (optional), the event to be called when the program has exited.
If you don't supply this, a warning will be printed if the exit status is
nonzero. To explicitly ignore it, set this to C<undef>.

B<'Timeout'> (optional), a timeout in seconds after which the program will
be forcibly killed if it is still running. There is no timeout by default.

B<'Context'> (optional), a variable which will be sent back to you with every
event. If you pass a reference, that same reference will be delivered back
to you later (not a copy), so you can update it as you see fit.

B<'WheelArgs'> (optional), a hash reference of options which will be passed
verbatim to the underlying POE::Wheel::Run object's constructor. Possibly
useful if you want to change the input/output filters and such.

=head2 C<killall>

This kills all currently running programs which POE::Quickie is managing.

=head2 C<programs>

Returns a hash reference of all the currently running programs. The key
is the process id, and the value is the context variable, if any.

=head1 OUTPUT

The following events might get sent to your session. The names correspond
to the options to L<C<run>|/run>.

=head2 StdoutEvent

=over 4

=item C<ARG0>: the chunk of STDOUT generated by the program

=item C<ARG1>: the process id of the child process

=item C<ARG2>: the context variable, if any

=back

=head2 StderrEvent

=over 4

=item C<ARG0>: the chunk of STDERR generated by the program

=item C<ARG1>: the process id of the child process

=item C<ARG2>: the context variable, if any

=back

=head2 ExitEvent

=over 4

=item C<ARG0>: the exit code produced by the program

=item C<ARG1>: the process id of the child process

=item C<ARG2>: the context variable, if any

=back

=head1 FUNCTIONS

The usage of these functions is modeled after the ones provided by
L<Capture::Tiny|Capture::Tiny>. They will not return until the executed
program has exited. However,
L<C<run_one_timeslice>|POE::Kernel/run_one_timeslice> in POE::Kernel will be
called in the meantime, so the rest of your application will continue to run.

They all take the same arguments as the L<C<run>|/run> method, except for the
B<'*Event'> and B<'Context'> arguments.

=head2 C<quickie>

Returns 3 values: the stdout, stderr, and exit code of the program.

=head2 C<quickie_tee>

Returns 3 values: the stdout, stderr, and exit code of the program. In
addition, it will echo the stdout/stderr to your program's stdout/stderr.
Beware that stdout and stderr in the merged result are not guaranteed to be
properly ordered due to buffering.

=head2 C<quickie_merged>

Returns 2 values: the merged stdout & stderr, and exit code of the program.

=head2 C<quickie_tee_merged>

Returns 2 values: the merged stdout & stderr, and exit code of the program.
In addition, it will echo the merged stdout & stderr to your program's
stdout. Beware that stdout and stderr in the merged result are not guaranteed
to be properly ordered due to buffering.

=head1 AUTHOR

Hinrik E<Ouml>rn SigurE<eth>sson, hinrik.sig@gmail.com

=head1 LICENSE AND COPYRIGHT

Copyright 2010 Hinrik E<Ouml>rn SigurE<eth>sson

This program is free software, you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
