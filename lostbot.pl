#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use Encode qw<decode>;
use List::MoreUtils qw<firstidx>;
use POE;
use POE::Component::IRC;
use POE::Component::IRC::Common qw<irc_to_utf8>;
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

    $irc = POE::Component::IRC->spawn(
        server       => 'localhost',
        port         => 50555,
        nick         => 'gamesurge',
        password     => 'livetogetherdiealone',
        debug        => 1,
        plugin_debug => 1,
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
    my $what = irc_to_utf8($_[ARG2]);

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

    my $entry_no = int rand @scripts;

    # let's not start with quotes of fewer than 3 words
    while ((my @words = split /\s+/, $scripts[$entry_no]->[4]) < 5) {
        $entry_no = int rand @scripts;
    }

    $active{entry} = $scripts[$entry_no];
    $active{next} = $entry_no+1;
    $active{points} = 25;
    $active{count} = $count;
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

    my @scores = map { "$_: ".$scores{$_} } sort { $scores{$b} <=> $scores{$a} } keys %scores;
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
    start_game($where, $count) if $count > 0;
}

sub try_guess {
    my ($who, $where, $try) = @_;

    my ($title, @number) = @{$active{entry}}[0..2];
    for ($title, $try) {
        $_ = lc $_;
        s/[,.']//g;
        s/é/e/g;
    }

    my $short = join '', map { substr $_, 0, 1 } split /\s+/, $title;
    s/^(?:The|An?) //i for ($title, $try);
    
    my $short_num = sprintf "%dx%.2d", @number;
    my $long_num = sprintf "s%.2de%.2d", @number;

    if ($try =~ /\s*\Q$title\E\s*/ || $short =~ tr/A-z// > 2 && $try =~ /\b$short\b/
            || $try =~ /\b$short_num\b/ || $try =~ /\b$long_num\b/) {
        my $pts = $active{points};
        $scores{$who} += $pts;
        my $rank = firstidx { $_->[0] eq $who }
                   sort { $b->[1] <=> $a->[1] }
                   map { [$_ => $scores{$_}] } keys %scores;
        $rank++;
        save_scores();
        $irc->yield(privmsg => $where,"$who: You win $pts points! (".answer()."). Your rank: $rank");
        stop_game();
    }
}

sub read_transcripts {
    chdir 'transcripts';
    my @files = glob '*.txt';

    for my $file (@files) {
        open my $script, '<:encoding(utf8)', $file or die "Can't open '$file': $!";
        $file = decode('utf8', $file);
        my ($season, $episode, $title) = $file =~ /^(\d+)x(\d+) - (.+)\.txt/;

        while (my $line = <$script>) {
            chomp $line;
            next if $line =~ /^\s*$/;           # no empty lines
            $line =~ s/\[(?!Subtitle).+?\]//g;  # remove non-dialogue stuff
            next if !length $line;
            if (my ($subtitle) = $line =~ /\[Subtitle: (.*?)\]/) {
                $line = $subtitle;
            }

            if (my ($who, $what) = $line =~ /^(.+?):\s*(.+)/) {
                push @scripts, [$title, $season, $episode, $who, $what];
            }
        }
    }
    
    chdir '..';
}
