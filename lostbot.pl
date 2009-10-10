#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use POE;
use POE::Component::IRC::State;
use POE::Component::IRC::Plugin::Connector;
use POE::Component::IRC::Plugin::NickReclaim;
use POE::Component::IRC::Plugin::CTCP;
use POE::Component::IRC::Plugin::AutoJoin;
use YAML::Any qw<DumpFile LoadFile>;

my ($irc, @scripts, %active, %scores);

POE::Session->create(
    package_states => [
        (__PACKAGE__) => [qw(
            _start
            irc_public
            give_hint
        )],
    ],
);

POE::Kernel->run();

sub _start {
    load_scores();
    read_transcripts();

    $irc = POE::Component::IRC::State->spawn(
        #nick         => 'gamesurge',
        #server       => 'localhost',
        #port         => 50555,
        #password     => 'livetogetherdiealone',
        server        => 'irc.gamesurge.net',
        nick          => 'LostTrivia',
        username      => 'tawaret',
        ircname       => 'Lost Quote Trivia Bot',
        debug        => 1,
        plugin_debug => 1,
    );

    $irc->plugin_add(@$_) for (
        [Connector   => POE::Component::IRC::Plugin::Connector->new()],
        [CTCP        => POE::Component::IRC::Plugin::CTCP->new()],
        [NickReclaim => POE::Component::IRC::Plugin::NickReclaim->new()],
        [AutoJoin    => POE::Component::IRC::Plugin::AutoJoin->new(
            Channels => ['#lostpedia'],
        )],
    );

    $irc->yield('connect');
}

sub load_scores {
    %scores = %{ LoadFile('scores.yml') };
}

sub save_scores {
    DumpFile('scores.yml', \%scores);
}

sub irc_public {
    my $who = (split /!/, $_[ARG0])[0];
    my $where = $_[ARG1]->[0];
    my $what = $_[ARG2];

    if ($what =~ /^,quote\b/i && !keys %active) {
        my $count = 1;
        ($count) = $what =~ /^,quote\s+(\d+)/;
        $count = 10 if defined $count && $count > 10;
        start_game($where, $count);
    }
    elsif ($what =~ /^,scores?$/i) {
        print_scores($where);
    }
    elsif (keys %active) {
        try_guess($who, $where, $what);
    }
}

sub start_game {
    my ($where, $count) = @_;

    my $entry_no = int rand $#scripts;
    $active{entry} = $scripts[$entry_no];
    $active{next} = $entry_no+1;
    $active{points} = 25;
    $active{count} = $count if $count;
    $active{where} = $where;
    $irc->yield(privmsg => $where, "“$active{entry}[4]”");
    $poe_kernel->delay(give_hint => 20, $where);
}

sub give_hint {
    my ($where) = $_[ARG0];
    return if !$irc->connected();

    $active{hints}++;
    $poe_kernel->delay(give_hint => 20, $where);
    my $next = $active{next};

    if ($active{hints} == 1) {
        # reveal who said the quote
        my ($who, $quote) = @{$active{entry}}[3..4];
        my $msg = "$who: “$quote”";
        $irc->yield(privmsg => $where, $msg);
        $active{points} -= 10;
    }
    elsif ($active{hints} == 4) {
        $irc->yield(privmsg => $where, "Time's up! Answer: ".answer());
        stop_game();
    }
    # TODO: do something clever when the reach the end of the episode
    #elsif (!defined $scripts[$next]) {
    #    # no more quotes
    #    $irc->yield(privmsg => $where, "That's the end of the episode!");
    #}
    else {
        # give away the next quote
        $active{entry} = $scripts[$next];
        my ($who, $quote) = @{$active{entry}}[3..4];
        my $msg = "$who: “$quote”";
        $irc->yield(privmsg => $where, $msg);
        $active{next}++;
        $active{points} -= 5;
    }
}

sub print_scores {
    my ($where) = @_;

    if (!keys %scores) {
        $irc->yield(privmsg => $where, 'No scores yet');
    }

    my @scores = map { "$_: ".$scores{$_} } keys %scores;
    my $string = '';
    while (@scores) {
        $string .=  (length $string ? ', ' : '') . shift @scores;
        if (length $string > 200) {
            $irc->yield(privmsg => $where, $string);
            $string = '';
        }
    }
    $irc->yield(privmsg => $where, $string) if length $string;
}

sub answer {
    my ($title, @number) = @{$active{entry}}[0..2];
    return sprintf '%dx%.2d - %s', @number, $title;
}

sub stop_game {
    $active{count}--;
    $poe_kernel->delay('give_hint');
    my ($where, $count) = @active{qw(where count)};
    undef %active;
    start_game($where, $count) if $count;
}

sub try_guess {
    my ($who, $where, $what) = @_;

    my ($title, @number) = @{$active{entry}}[0..2];
    my $try = lc $what;
    for ($title, $try) {
        $_ = lc $_;
        s/[,.']//g;
        s/é/e/g;
    }

    my $short = join '', map { substr $_, 0, 1 } split /\s+/, $title;
    s/^(?:The|An?) //i for ($title, $try);
    
    my $short_num = sprintf "%dx%.2d", @number;
    my $long_num = sprintf "s%.2de%.2d", @number;

    if ($try =~ /\b\Q$title\E\b/ || $short =~ tr/A-z// > 2 && $try =~ /\b$short\b/
            || $try =~ /\b$short_num\b/ || $try =~ /\b$long_num\b/) {
        my $pts = $active{points};
        $scores{$who} += $pts;
        save_scores();
        $irc->yield(privmsg => $where, "$who: You win $pts points! (".answer().')');
        stop_game();
    }
}

sub read_transcripts {
    chdir 'transcripts';
    my @files = glob '*.txt';

    for my $file (@files) {
        open my $script, '<:encoding(utf8)', $file or die "Can't open '$file': $!";
        my ($season, $episode, $title) = $file =~ /^(\d+)x(\d+) - (.+)\.txt/;

        while (my $line = <$script>) {
            chomp $line;
            next if $line =~ /^\s*$/;  # no empty lines
            next if $line =~ /^\[/;    # no non-dialogue lines
            $line =~ s/\[(?!Subtitle).+?\]//g;     # remove non-dialogue stuff

            if (my ($who, $what) = $line =~ /^(.+?):\s*(.+)/) {
                push @scripts, [$title, $season, $episode, $who, $what];
            }
        }
    }
    
    chdir '..';
}
