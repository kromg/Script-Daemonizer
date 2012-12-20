use 5.006;
use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                => 'Script::Daemonizer',
    AUTHOR              => q{Giacomo Montagner <gmork@entirelyunlike.net>},
    VERSION_FROM        => 'lib/Script/Daemonizer.pm',
    ABSTRACT_FROM       => 'lib/Script/Daemonizer.pm',
    ($ExtUtils::MakeMaker::VERSION >= 6.3002
      ? ('LICENSE'=> 'perl')
      : ()),
    PL_FILES            => {},
    PREREQ_PM => {
        'Test::More' => 0,
    },
    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean               => { FILES => 'Script-Daemonizer-*' },
);
