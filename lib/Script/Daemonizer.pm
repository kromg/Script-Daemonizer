package Script::Daemonizer;

use 5.006;
use strict;
use warnings;
use Carp qw/carp croak/;
use POSIX ();
use Fcntl qw/:DEFAULT :flock/;

@Script::Daemonizer::ISA = qw(Exporter);
@Script::Daemonizer::EXPORT = ();
@Script::Daemonizer::EXPORT_OK = qw(daemonize drop_privileges_to);

$Script::Daemonizer::VERSION = '0.01_01';

# ------------------------------------------------------------------------------
# 'Private' functions
# ------------------------------------------------------------------------------

###############
# sub _fork() #
###############
# fork() a child 
sub _fork() {
    # See http://code.activestate.com/recipes/278731/ or the source of 
    # Proc::Daemon for a discussion on ignoring SIGHUP. 
    # Since ignoring it across the fork() should not be harmful, I prefer to set
    # this to IGNORE anyway. 
    local $SIG{'HUP'} = 'IGNORE';

    defined(my $pid = fork()) or croak "Cannot fork: $!";
    exit 0 if $pid;     # parent exits here
}

#########################
# sub _max_open_files() #
#########################
# This comes from Prod::Daemon. κῦδος to Earl Hood and Detlef Pilzecker for
# their work. 
sub _max_open_files() {
    my $openmax = POSIX::sysconf( &POSIX::_SC_OPEN_MAX );

    return ( $openmax && $openmax > 0 ) ? 
        $openmax : 
        64;
}

#########################
# sub _write_pidfile($) #
#########################
sub _write_pidfile {
    my ($pidfile) = @_;

    my $fh;
    sysopen($fh, $pidfile, O_WRONLY | O_CREAT)
        || croak "can't open $pidfile: $!";
    flock($fh, LOCK_EX|LOCK_NB)
        || croak "can't lock $pidfile: $! - is another instance running?";
    truncate($fh, 0)
        || croak "can't truncate $pidfile: $!";

    my $prev = select $fh;
    ++$|;
    print $fh $$;
    select $prev;

    # Now we won't let this go out of scope, so that pid filehandle will always
    # be kept open and locked
    $Script::Daemonizer::pidfh = $fh;

    return fileno $Script::Daemonizer::pidfh;
}

#################
# sub _close_fh #
#################
sub _close_fh {
    shift;  # discard 'keep' label
    my $keep = shift;

    my %keep;
    # Get the FD for each FH passed (if any).
    if ($keep) {
        # See if we have an array ref
        croak "You must pass an array reference to 'keep' option"
            unless ref($keep) eq 'ARRAY';

        # Get all file descriptors (assume numbers to be file descriptor)
        foreach (@$keep) {
            my $fd = /^\d+$/ ? $_ : fileno($_);
            $keep{ $fd } = 1 if defined $fd;  
        } 
    } 

    # First of all, try to close STDIN and reopen it from /dev/null
    unless ($keep{0}) {
        close(STDIN);
        open STDIN, '<', '/dev/null'
            or croak "Cannot open /dev/null for reading: $!";
    }

    # STDOUT and STDERR are managed separately, because 

    # Other taken from - or inspired by - Proc::Daemon
    # Here is the original comment: 
        # Since <POSIX::close(FD)> is in some cases "secretly" closing
        # file descriptors without telling it to perl, we need to
        # re<open> and <CORE::close(FH)> as many files as we closed with
        # <POSIX::close(FD)>. Otherwise it can happen (especially with
        # FH opened by __DATA__ or __END__) that there will be two perl
        # handles associated with one file, what can cause some
        # confusion.   :-)
        # see: http://rt.perl.org/rt3/Ticket/Display.html?id=72526
    my $highest_fd = -1;
    for (3 .. _max_open_files) {
        next if $keep{ $_ };
        $highest_fd = $_ if POSIX::close($_);
    }

    # Now I reopen all filehandles for reading from /dev/null; again, from
    # Proc::Daemon: 
        # Perl will try to close all handles when @fh leaves scope
        # here, but the rude ones will sacrifice themselves to avoid
        # potential damage later
    { 
        my @fh;
        my $cur = 0;
        while ($cur <= $highest_fd) {
            open $fh[ $_ ], '<', '/dev/null' or
                croak "Cannot open /dev/null for reading: $!";
            $cur = fileno( $fh[ $_ ] );
        }
    }

    # Delay closing STDOUT and STDERR until we see if they must be tied to 
    # syslog. See _manage_stdhandles()

    return %keep;
}

#################
# sub _close($) #
#################
# Handle closing of STDOUT/STDERR
sub _close($) {
    my $fh = shift;
    close *$fh 
        or croak "Unable to close $fh: $!";
    open *$fh, '>', '/dev/null' 
        or croak "Unable to reopen $fh on /dev/null: $!";
}

##########################
# sub _manage_stdhandles #
##########################
sub _manage_stdhandles {
    my %params = @_;

    my $keep = $params{'keep'};
    my %keep = map { $_ => 1 } @$keep;

    # If we were not requested to tie stdhandles, we may safely close them and
    # return now. 
    if ($params{'do_not_tie_stdhandles'}) {
        _close 'STDOUT' unless ($keep{1} or $keep{'STDOUT'});
        _close 'STDERR' unless ($keep{2} or $keep{'STDERR'});
        return 1;
    }

    # Try to load Tie::Syslog and issue a warning if module cannot be loaded
    eval 'require Tie::Syslog;';
    if ($@) {
        carp "Unable to load Tie::Syslog module: $@. I will continue without output.";
        _close 'STDOUT' unless ($keep{1} or $keep{'STDOUT'});
        _close 'STDERR' unless ($keep{2} or $keep{'STDERR'});
        return;
    }

    $Tie::Syslog::ident  = $params{'name'};
    $Tie::Syslog::logopt = 'ndelay,pid';

    unless ($keep{1} or $keep{'STDOUT'}) {
        close STDOUT
            or croak "Unable to close STDOUT: $!";
        tie *STDOUT, 'Tie::Handle', {
            facility => 'LOG_LOCAL0',
            priority => 'LOG_INFO',
        };
    }

    unless ($keep{2} or $keep{'STDERR'}) {
        close STDERR
            or croak "Unable to close STDERR: $!";
        tie *STDERR, 'Tie::Handle', {
            facility => 'LOG_LOCAL0',
            priority => 'LOG_ERR',
        };
    }
}

# ------------------------------------------------------------------------------
# 'Public' functions
# ------------------------------------------------------------------------------

sub daemonize {
    croak "Odd number of arguments in configuration!"
        if @_ %2;

    # Get the configuration
    my %params = @_;

    # Set useful defaults
    $params{'name'}        ||= (split '/', $0)[-1];
    $params{'umask'}       ||= 0;
    $params{'working_dir'} ||= '/';

    # Step 1.
    umask($params{'umask'}) or 
        croak "Cannot set umask", $params{'umask'}, ": $!";

    # Step 2.
    _fork();

    # Step 3.
    POSIX::setsid() or 
        croak "Unable to set session id: $!";

    # Step 4.
    _fork();

    # Step 5.
    chdir($params{'working_dir'}) or 
        croak "Cannot change directory to ", $params{'working_dir'}, ": $!";

    # Step 5.5 - create pidfile if requested. Do this before closing handles
    # so that
    #  1st) we may keep it open in step 6, knowing its file descriptor
    #  2nd) in case of errors, we still get a chance to throw a readable message
    #       (hopefully)
    push @{ $params{'keep'} }, _write_pidfile($params{'pidfile'})
        if $params{'pidfile'};

    # Step 6.
    _close_fh(keep => $params{'keep'}) 
        unless $params{'do_not_close_fh'};

    # Step 7.
    _manage_stdhandles(%params) unless $params{'do_not_close_fh'};;
    
}


1; # End of Script::Daemonizer

__END__

