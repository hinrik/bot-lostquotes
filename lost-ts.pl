#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use Encode qw<decode>;
use POE;
use POE::Component::IRC;
use POE::Component::IRC::Common qw<irc_to_utf8>;

use constant {
    TITLE  => 0,
    SEASON => 1,
    EP     => 2,
    CHAR   => 3,
    LINE   => 4,
};

my ($irc, @scripts);

POE::Session->create(
    package_states => [
        (__PACKAGE__) => [qw(
            _start
            irc_public
        )],
    ],
);

POE::Kernel->run();

sub _start {
    read_transcripts();

    $irc = POE::Component::IRC->spawn(
        server       => 'localhost',
        port         => 50667,
        nick         => 'rizon',
        password     => 'livetogetherdiealone',
        debug        => 1,
        plugin_debug => 1,
    );

    $irc->yield('connect');
}

sub irc_public {
    my $who = (split /!/, $_[ARG0])[0];
    my $where = $_[ARG1]->[0];
    my $what = irc_to_utf8($_[ARG2]);

    if ($what =~ s/^,ts\s+//i) {
        my $entry = find_quote($what);
        my $msg = defined $entry
            ? "[$entry->[SEASON]x$entry->[EP]] $entry->[CHAR]: “$entry->[LINE]”"
            : 'No matching quotes found.';
        $irc->yield(privmsg => $where, $msg);
    }
}

sub find_quote {
    my ($query) = @_;

    my (%params, $entry);

    # parse optional parameters
    while ($query =~ s/^([cse])=("[^"]+"|\S+)\s*//g) {
        my ($key, $value) = ($1, $2);
        $value =~ s/^"|"$//g;
        $params{$key} = $value;
    }

    for my $candidate (@scripts) {
        if (defined $params{c}) {
            next if lc($candidate->[CHAR]) ne lc($params{c});
        }
        if (defined $params{s}) {
            next if $candidate->[SEASON] != $params{s};
        }
        if (defined $params{e}) {
            if (defined $params{s}) {
                next if $candidate->[EP] != $params{e};
            }
            else {
                my ($season, $ep) = $params{e} =~ /^(\d)x(\d+)$/;
                next if $candidate->[SEASON] != $season;
                next if $candidate->[EP] != $ep;
            }
        }

        return $candidate if !length $query;

        if ($query =~ m{^/}) {
            # regex search
            my ($regex) = $query =~ m{/(.*)/};
            next if !eval { $candidate->[LINE] =~ /$regex/ };
        }
        else {
            # case-insensitive word search
            next if $candidate->[LINE] !~ /\b\Q$query\E\b/i;
        }
        return $candidate;
    }

    return;
}

sub read_transcripts {
    chdir 'transcripts';
    my @files = glob '*.txt';

    for my $file (@files) {
        open my $script, '<:encoding(utf8)', $file or die "Can't open '$file': $!";
        $file = decode('utf8', $file);
        my ($season, $episode, $title) = $file =~ /^(\d+)x(\d+) - (.+)\.txt$/;

        while (my $line = <$script>) {
            chomp $line;
            next if $line =~ /^\s*$/;              # skip empty lines
            $line =~ s/\[(?!Subtitle).+?\]\s*//g;  # remove non-dialogue stuff
            next if !length $line;

            if (my ($who, $what) = $line =~ /^(.+?):\s*(.+)\s*/) {
                if (my ($subtitle) = $what =~ /\[Subtitle: (.*?)\]/) {
                    $what = $subtitle;
                }
                push @scripts, [$title, $season, $episode, $who, $what];
            }
        }
    }
    
    chdir '..';
}
