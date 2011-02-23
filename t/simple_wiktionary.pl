#!/usr/bin/perl -w

use Test::More;
#use AnyEvent::Redis;
use Redis;
use Data::Dumper;

my %test_words = (
    free => 6,
    about => 3,
    'pacific ocean' => 1, # phrase
    actuality => 2, 
    set => 15,
    #ramparts => 1, # only in en Wikipedia
    #'touch base' => 2, # only in en Wikipedia
    seoul => 1,  # capitalised in dict
    underscores => 1,
    rages => 1, # markup is {{noun|rage|rages}} - how to handle?
    "cell-phone" => 1, # handle redirects?
    trombones => 1, # handle plural-only entries
    linking => 1, # past participle ref
    philanthropy => 1,
);

my $REDIS_SERVER_IP = '127.0.0.1:6379';
my $r;

eval{
    $r = Redis->new(server => $REDIS_SERVER_IP);
};

plan tests => scalar keys(%test_words);

for my $test_word (keys %test_words){
    print STDERR "Word:$test_word\n";
    my @vals = $r->lrange($test_word, 0, -1);
    is scalar @vals, $test_words{$test_word}, "Correct defns # for $test_word:" . @vals;
}

done_testing;
