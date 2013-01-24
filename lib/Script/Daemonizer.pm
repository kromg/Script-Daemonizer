package Script::Daemonizer;

use 5.006;
use strict;
use warnings;
use Carp qw/carp croak/;
use POSIX qw(:signal_h);
use Fcntl qw/:DEFAULT :flock/;
use FindBin ();
use File::Spec;
use File::Basename ();

$Script::Daemonizer::VERSION = '0.93.00';

# ------------------------------------------------------------------------------
# 'Private' vars
# ------------------------------------------------------------------------------
my @argv_copy;
my $devnull = File::Spec->devnull;
my @daemon_options = ( qw{ 
    do_not_tie_stdhandles
    drop_privileges
    pidfile

    _DEBUG
} );



################################################################################
# SAVING @ARGV for restart()
################################################################################
#
# restart() needs the exact list of arguments in order to relaunch the script, 
# if requested.
# User is free to shift(@ARGV) and/or modify it in any way, we ensure we always
# get the "real" args (unless someone takes some extra effort to modify them 
# before we get here).
# restart() gets an array of args, thoug, so there is no need to tamper with
# this: 

BEGIN {
    @argv_copy = @ARGV;
}

################################################################################
# HANDLING SIGHUP
################################################################################
# 
# When the script restarts itself upon receiving SIGHUP, that signal is masked. 
# When starting, we unmask the signals so that they do not stop working for us. 
# We do this regardless of how we were launched. 
#
{ 
    my $sigset = POSIX::SigSet->new( SIGHUP );  # Just handle HUP
    sigprocmask(SIG_UNBLOCK, $sigset);
}


    


# ------------------------------------------------------------------------------
# 'Private' functions
# ------------------------------------------------------------------------------

################
# sub _debug() #
################

sub _debug {
    my $self = shift;
    print @_, "\n" 
        if $self->{'_DEBUG'};
}

###############
# sub _fork   #
###############
# fork() a child 
sub _fork {
    my $self = shift;

    return unless $self->{'fork'};

    # See http://code.activestate.com/recipes/278731/ or the source of 
    # Proc::Daemon for a discussion on ignoring SIGHUP. 
    # Since ignoring it across the fork() should not be harmful, I prefer to set
    # this to IGNORE anyway. 
    local $SIG{'HUP'} = 'IGNORE';

    defined(my $pid = fork()) or croak "Cannot fork: $!";
    exit 0 if $pid;     # parent exits here
    $self->{'fork'}--;

    $self->_debug("Forked, remaining forks: ", $self->{'fork'});

}

#   #########################
#   # sub _max_open_files   #
#   #########################
#   # This comes from Prod::Daemon. κῦδος to Earl Hood and Detlef Pilzecker for
#   # their work. 
#   sub _max_open_files {
#       my $openmax = POSIX::sysconf( &POSIX::_SC_OPEN_MAX );
#   
#       return ( $openmax && $openmax > 0 ) ? 
#           $openmax : 
#           64;
#   }

#########################
# sub _write_pidfile    #
#########################
# Open the pidfile (creating it if necessary), then lock it, then truncate it,
# then write pid into it. Then retun filehandle. 
# If environment variable $_pidfile_fileno is set, then we assume we're product
# of an exec() and take that file descriptor as the (already opened) pidfile.
sub _write_pidfile {
    my $self = shift;
    my $pidfile = $self->{'pidfile'};
    my $fh;

    # First we must see if there is a _pidfile_fileno variable in environment;
    # that means that we were started by an exec() and we must keep the same 
    # pidfile as before
    my $pidfd = delete $ENV{_pidfile_fileno};
    if (defined $pidfd && $pidfd =~ /^\d+$/) {
        $self->_debug("Reopening pidfile from file descriptor");
        open($fh, ">&=$pidfd") 
            or croak "can't open fd $pidfd: $!";
        # Re-set close-on-exec bit for pidfile filehandle
        fcntl($fh, F_SETFD, 1)
            or die "Can't set close-on-exec flag on pidfile filehandle: $!\n";
    } else {
        $self->_debug("Opening a new pid file");
        # Open configured pidfile
        sysopen($fh, $pidfile, O_RDWR | O_CREAT)
            or croak "can't open $pidfile: $!";
    }
    flock($fh, LOCK_EX|LOCK_NB)
        or croak "can't lock $pidfile: $! - is another instance running?";
    truncate($fh, 0)
        or croak "can't truncate $pidfile: $!";

    my $prev = select $fh;
    ++$|;
    select $prev;

    return $self->{'pidfh'} = $fh;
}

#   ###################
#   # sub _close_fh   #
#   ###################
#   # This closes all filehandles. See perldoc Script::Daemonizer for caveats.
#   sub _close_fh {
#       shift;  # discard 'keep' label
#       my $keep = shift;
#       my %keep;
#   
#       # Get the FD for each FH passed (if any).
#       if ($keep) {
#           # See if we have an array ref
#           croak "You must pass an array reference to 'keep' option"
#               unless ref($keep) eq 'ARRAY';
#   
#           # Get all file descriptors (assume numbers to be file descriptor)
#           foreach (@$keep) {
#               $keep{ $_ } = 1, next 
#                   if /^\d+$/;
#               no strict "refs";   # Have to lookup handles symblically
#               # If filehandle name is unqualified I qualify it as *main::FH
#               my $fd = fileno( 
#                   ref($_) eq 'GLOB' ? $_ :
#                                /::/ ? $_ : "main::$_" 
#               );
#               $keep{ $fd } = 1 if defined $fd;
#           } 
#       } 
#   
#       # First of all, try to close STDIN and reopen it from /dev/null
#       unless ($keep{0}) {
#           close(STDIN);
#           open STDIN, '<', $devnull
#               or croak "Cannot open $devnull for reading: $!";
#       }
#   
#       # -------------------------------------------------------------------------
#       # STDOUT and STDERR are managed separately, because we must see if user
#       # requested to tie them to syslog. Also, closing STDOUT and STDERR as late
#       # as possible, any error message or warning has still a chance to be spit
#       # out somewhere.
#       # See _manage_stdhandles()
#       # -------------------------------------------------------------------------
#   
#       # Other code taken from - or inspired by - Proc::Daemon
#       # Here is the original comment: 
#           # Since <POSIX::close(FD)> is in some cases "secretly" closing
#           # file descriptors without telling it to perl, we need to
#           # re<open> and <CORE::close(FH)> as many files as we closed with
#           # <POSIX::close(FD)>. Otherwise it can happen (especially with
#           # FH opened by __DATA__ or __END__) that there will be two perl
#           # handles associated with one file, what can cause some
#           # confusion.   :-)
#           # see: http://rt.perl.org/rt3/Ticket/Display.html?id=72526
#       my $highest_fd = -1;
#       for (3 .. _max_open_files) {
#           next if $keep{ $_ };
#           $highest_fd = $_ if POSIX::close($_);
#       }
#   
#       # Now I reopen all filehandles for reading from /dev/null; again, from
#       # Proc::Daemon: 
#           # Perl will try to close all handles when @fh leaves scope
#           # here, but the rude ones will sacrifice themselves to avoid
#           # potential damage later
#       { 
#           my @fh;
#           my $cur = -1;
#           while ($cur < $highest_fd) {
#               open my $fh, '<', $devnull
#                   or croak "Cannot open $devnull for reading: $!";
#               push @fh, $fh;
#               $cur = fileno( $fh );
#               print "Reopened $cur fd\n";
#           }
#       }
#   
#       return %keep;
#   }

#################
# sub _close    #
#################
# Handle closing of STDOUT/STDERR
sub _close {
    my $self = shift;
    my $fh = shift;
    # Have to lookup handles by name
    no strict "refs";
    close *$fh 
        or croak "Unable to close $fh: $!";
    my $destination = $self->{'_DEBUG'} || $devnull;
    open *$fh, '+>>', $destination
        or croak "Unable to reopen $fh on $destination: $!";
        # I'd really like to see whenever this "croak" will actually print 
        # somewhere, anyway...

    if ($self->{'_DEBUG'}) {
        my $prev = select *$fh;
        ++$|;
        select $prev;
    }

}

##########################
# sub _manage_stdhandles #
##########################
sub _manage_stdhandles {
    my $self = shift;

    open STDIN, '<', $devnull
        or croak "Cannot reopen STDIN on $devnull: $!";

    # my $keep = $self->{'keep'};
    # # I do not go through the same analysis done in _close_fh() because I can
    # # name the filehandles I'm acting upon: they're called STDOUT (1) and
    # # STDERR (2)
    # my %keep = map { $_ => 1 } @$keep;

    # # Return immediately if we have nothing to do:
    # return 1 if ( 
    #     ($keep{1} or $keep{'STDOUT'}) && ($keep{2} or $keep{'STDERR'}) 
    # );

    # If we were not requested to tie stdhandles, we may safely close them and
    # return now. 
    if ($self->{'do_not_tie_stdhandles'}) {
        # _close 'STDOUT' unless ($keep{1} or $keep{'STDOUT'});
        # _close 'STDERR' unless ($keep{2} or $keep{'STDERR'});
        $self->_close( $_ ) for (qw{STDOUT STDERR});
        return 1;
    }

    eval {
        require Tie::Syslog;
    };

    if ($@) {
        carp "Unable to load Tie::Syslog module. Error is:\n----\n$@----\nI will continue without output";
        # _close 'STDOUT' unless ($keep{1} or $keep{'STDOUT'});
        # _close 'STDERR' unless ($keep{2} or $keep{'STDERR'});
        $self->_close( $_ ) for (qw{STDOUT STDERR});
        return 0;
    }

    # DEFAULT: tie to syslog

    $Tie::Syslog::ident  = $self->{'name'};
    $Tie::Syslog::logopt = 'ndelay,pid';

    #unless ($keep{1} or $keep{'STDOUT'}) {
        close STDOUT
            or croak "Unable to close STDOUT: $!";
        tie *STDOUT, 'Tie::Syslog', {
            facility => 'LOG_DAEMON',
            priority => 'LOG_INFO',
        };
    #}

    #unless ($keep{2} or $keep{'STDERR'}) {
        close STDERR
            or croak "Unable to close STDERR: $!";
        tie *STDERR, 'Tie::Syslog', {
            facility => 'LOG_DAEMON',
            priority => 'LOG_ERR',
        };
    #}
    
}

# ------------------------------------------------------------------------------
# 'Public' functions
# ------------------------------------------------------------------------------

sub drop_privileges {

    my $self = shift;

    # Check parameters:
    croak "Odd number of arguments in drop_privileges() call!"
        if @_ % 2;

    my %ids = @_ ? @_ : %{ $self->{'drop_privileges'} };
    my ($euid, $egid, $uid, $gid) = @ids{qw(euid egid uid gid)};

    # Drop GROUP ID
    if (defined $gid) {
        POSIX::setgid((split " ", $gid)[0])
            or croak "POSIX::setgid() failed: $!";
    } elsif (defined $egid) {
        # $egid might be a list
        $) = $egid; 
        croak "Cannot drop effective group id to $egid: $!"
            if $!;
    }

    if (defined $uid) {
        POSIX::setuid($uid)
            or croak "POSIX::setuid() failed: $!";
    } elsif (defined $euid) {
        # Drop EUID too, unless explicitly forced to something else
        $> = $euid;
        croak "Cannot drop effective user id to $uid: $!"
            if $!;
    }

    return 1;

}

sub new {

    my $pkg = shift;

    croak ("This is a class method!")
        if ref($pkg);

    croak "Odd number of arguments in configuration!"
        if @_ %2;

    my $self = {};

    # Get the configuration
    my %params = @_;

    # Set useful defaults
    $self->{'name'}        = delete $params{'name'}        || (File::Spec->splitpath($0))[-1];
    $self->{'umask'}       = delete $params{'umask'}       || 0;
    $self->{'working_dir'} = delete $params{'working_dir'} || File::Spec->rootdir();
    $self->{'fork'}        = (exists $params{'fork'} && $params{'fork'} =~ /^[012]$/) ? 
                             delete $params{'fork'}         : 2;

    # Get other options as they are:
    for (@daemon_options) {
        $self->{ $_ } = delete $params{ $_ };
    }

    my @extra_args = keys %params;
    {
        local $" = ", ";
        croak sprintf "Invalid argument(s) passed: @extra_args"
            if @extra_args;
    }

    return bless $self, $pkg; 

}

sub daemonize {
    my $self = shift;

    # Step 0.0 - OPTIONAL: drop privileges
    $self->drop_privileges
        if $self->{'drop_privileges'};

    # Step 0.1 - OPTIONAL: take a lock on pidfile
    # push @{ $self->{'keep'} }, fileno($pidfh = _write_pidfile($self->{'pidfile'}))
    #     if $self->{'pidfile'};
    $self->_write_pidfile()
        if $self->{'pidfile'};

    # Step 1.
    defined(umask($self->{'umask'})) or 
        croak qq(Cannot set umask to "), $self->{'umask'}, qq(": $!);

    # Step 2.
    $self->_fork();

    # Step 3.
    POSIX::setsid() or 
        croak "Unable to set session id: $!";

    # Step 4.
    $self->_fork();
    
    #
    # Step 4.5 - OPTIONAL: if pidfile is in use, now it's the moment to dump our
    # pid into it.
    #
    ### NEW from 0.92.00 - try to lock pidfile again: on some platforms* the
    # lock is not preserved across fork(), so we must ensure again that no one
    # is holding the lock. This allows a tiny race condition between the first
    # and the second lock attempt, however nothing harmful is done between these
    # two operations - steps 1 to 4 can be done safely even if another instance
    # is running. The only reason I didn't remove the first flock() attempt is
    # that if we need to fail and we have the chance to do it sooner, then it's
    # preferable, since at step 0.1 we're still attached to our controlling
    # process (and to the terminal, if launched by user) and the failure is more
    # noticeable (maybe).
    #
    # * Failing platforms (from CPANTesters): FreeBSD, Mac OS X, OpenBSD, Solaris;
    #   Linux and NetBSD seem to be unaffected.
    # 
    if ($self->{'pidfh'}) {
        my $pidfh = $self->{'pidfh'};
        flock($pidfh, LOCK_EX|LOCK_NB)
            or croak "can't lock ", $self->{'pidfile'}, ": $! - is another instance running?";
        print $pidfh $$;
    }

    # Step 5.
    chdir($self->{'working_dir'}) or 
        croak "Cannot change directory to ", $self->{'working_dir'}, ": $!";

    # # Step 6.
    # _close_fh(keep => $self->{'keep'}) 
    #     unless $self->{'do_not_close_fh'};

    # Step 7.
    # _manage_stdhandles(%self->) unless $self->{'do_not_close_fh'};
    $self->_manage_stdhandles();

    return 1;
    
}

sub restart {

    my $self = shift;

    my @args = @_ ? @_ : @argv_copy;

    # See perlipc
    # make the daemon cross-platform, so exec always calls the script
    # itself with the right path, no matter how the script was invoked.
    my $script = File::Basename::basename($0);
    my $SELF = File::Spec->catfile($FindBin::Bin, $script);

    # $pidf must be kept open across exec() if we don't want race conditions:
    if (my $pidfh = $self->{'pidfh'}) {
        $self->_debug("Keeping current pidfile open");
        # Clear close-on-exec bit for pidfile filehandle
        fcntl($pidfh, F_SETFD, 0)
            or die "Can't clear close-on-exec flag on pidfile filehandle: $!\n";
        # Now we must notify ourseves that pidfile is already open
        $ENV{_pidfile_fileno} = fileno( $pidfh );
    }
    
    exec($SELF, @args)
        or croak "$0: couldn't restart: $!";

}

# Bye default, we unmask SIGHUP but, if other signals must be unmasked too, 
# then use this and pass in a list of signals to be unmasked.
sub sigunmask {
    my $self = shift;
    croak "sigunmask called without arguments"
        unless @_;
    no strict "refs";
    # Have to convert manually signal names into numbers. I remove the prefix
    # POSIX::[SIG] from signal name and add it back again, this allows user to
    # refer to signals in any way, for example: 
    # QUIT
    # SIGQUIT
    # POSIX::QUIT
    # POSIX::SIGQUIT
    my @sigs = map { 
        ( my $signal = $_ ) =~ s/^POSIX:://;
        $signal =~ s/^SIG//;
        $signal = "POSIX::SIG".$signal;
        &$signal 
    } @_;
    my $sigset = POSIX::SigSet->new( @sigs );  # Handle all given signals
    sigprocmask(SIG_UNBLOCK, $sigset);
}


'End of Script::Daemonizer'

__END__

