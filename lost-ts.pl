#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use Encode qw<decode>;
use List::Util qw<shuffle>;
use POE;
use POE::Component::IRC;
use POE::Component::IRC::Common qw<irc_to_utf8>;
use POE::Component::IRC::Plugin::BotCommand;
use Text::Capitalize;

use constant {
    TITLE  => 0,
    SEASON => 1,
    EP     => 2,
    CHAR   => 3,
    LINE   => 4,
    NUMBER => 5,
};

my %param2index = (
    s => SEASON,
    e => EP,
    c => CHAR,
);

my ($irc, @scripts);

POE::Session->create(
    package_states => [
        (__PACKAGE__) => [qw(
            _start
            irc_botcmd_ts
            irc_botcmd_tscount
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

    $irc->plugin_add('BotCommand', POE::Component::IRC::Plugin::BotCommand->new(
        Addressed      => 0,
        Prefix         => ',',
        Ignore_unknown => 1,
        Commands       => {
            ts      => 'Look up a line from the Lost transcripts',
            tscount => 'Count the matches of this query in the transcripts',
        },
    ));

    $irc->yield('connect');
}

sub irc_botcmd_ts {
    my $who   = (split /!/, $_[ARG0])[0];
    my $where = $_[ARG1];
    my $what  = irc_to_utf8($_[ARG2]);

    my ($params, $query) = parse_params($what);
    my $entry = find_quote($params, $query);

    if (defined $entry) {
        $irc->yield(privmsg => $where, "$entry->[CHAR]: “$entry->[LINE]”");
        my $url = "http://nix.is/quotes/$entry->[SEASON]x$entry->[EP].html#L$entry->[NUMBER]";
        $irc->yield(privmsg => $where, "Context: $url");
    }
    else {
        $irc->yield(privmsg => $where, 'No matching quotes found.');
    }
}

sub irc_botcmd_tscount {
    my $who   = (split /!/, $_[ARG0])[0];
    my $where = $_[ARG1];
    my $what  = irc_to_utf8($_[ARG2]);

    my ($params, $query) = parse_params($what);
    my $sort_param = delete $params->{sort};
    
    if (!defined $sort_param) {
        $irc->yield(privmsg => $where, "You must specify sort criteria, e.g. sort=c");
        return;
    }

    my @matches = find_quote($params, $query);
    if (!@matches) {
        $irc->yield(privmsg => $where, 'No matches quotes found.');
        return;
    }

    my $sort_index = $param2index{$sort_param};
    my %freq;

    for my $match (@matches) {
        my $value = $match->[$sort_index];
        $value = "$match->[SEASON]x$value" if $sort_index == EP;
        $freq{$value}++;
    }

    my $prefix = $sort_index eq SEASON ? 'S' : '';
    my @data = map {
        my $entry = $sort_index eq CHAR ? capitalize(lc $_) : $_;
        "$prefix$entry => $freq{$_}"
    } sort { $freq{$b} <=> $freq{$a} } keys %freq;

    $irc->yield(privmsg => $where, 'Matches: ' . join(', ', @data));
}

sub parse_params {
    my ($query) = @_;

    my %params;
    while ($query =~ s/([cse]|sort)=("[^"]+"|\S+)\s*//g) {
        my ($key, $value) = ($1, $2);
        $value =~ s/^"|"$//g;
        $params{$key} = $value;
    }

    return \%params, $query;
}

sub find_quote {
    my ($params, $query) = @_;

    my (@results, $entry);

    for my $candidate (shuffle(@scripts)) {
        if (defined $params->{c}) {
            next if lc($candidate->[CHAR]) ne lc($params->{c});
        }
        if (defined $params->{s}) {
            next if $candidate->[SEASON] != $params->{s};
        }
        if (defined $params->{e}) {
            if (defined $params->{s}) {
                next if $candidate->[EP] != $params->{e};
            }
            else {
                my ($season, $ep) = $params->{e} =~ /^(\d)x(\d+)$/;
                next if $candidate->[SEASON] != $season;
                next if $candidate->[EP] != $ep;
            }
        }

        if (!length $query) {
            wantarray ? push @results, $candidate : return $candidate;
        }

        if ($query =~ m{^/}) {
            # regex search
            my ($regex) = $query =~ m{/(.*)/};
            next if !eval { no re 'eval'; $candidate->[LINE] =~ /$regex/ };
        }
        else {
            # case-insensitive word search
            my $normal = $query;
            $normal =~ s/’/'/;
            my $fancy = $query;
            $fancy =~ s/'/’/;

            next if $candidate->[LINE] !~ /\b\Q$normal\E\b/i
            && $candidate->[LINE] !~ /\b\Q$fancy\E\b/i
        }

        wantarray ? push @results, $candidate : return $candidate;
    }

    return @results;
}

sub read_transcripts {
    chdir 'transcripts';
    my @files = glob '*.txt';

    for my $file (@files) {
        open my $script, '<:encoding(utf8)', $file or die "Can't open '$file': $!";
        $file = decode('utf8', $file);
        my ($season, $episode, $title) = $file =~ /^(\d+)x(\d+) - (.+)\.txt$/;

        my $line_no = 0;
        while (my $line = <$script>) {
            chomp $line;
            next if $line =~ /^\s*$/;              # skip empty lines
            $line_no++;
            $line =~ s/\[(?!Subtitle).+?\]\s*//g;  # remove non-dialogue stuff
            next if !length $line;

            if (my ($who, $what) = $line =~ /^(.+?):\s*(.+)\s*/) {
                if (my ($subtitle) = $what =~ /\[Subtitle: (.*?)\]/) {
                    $what = $subtitle;
                }
                push @scripts, [$title, $season, $episode, $who, $what, $line_no];
            }
        }
    }
    
    chdir '..';
}
