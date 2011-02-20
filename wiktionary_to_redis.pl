#!/usr/bin/perl -w

use MediaWiki::DumpFile;
use Data::Dumper;
use Redis;
use strict;

our $REDIS_SERVER_IP = "127.0.0.1:6379";
our $DEBUG = 1;
our %PARSERS = (
    'http://simple.wiktionary.org/wiki/Main_Page' => \&simplewik_parse,
    'http://en.wiktionary.org/wiki/Wiktionary:Main_Page' => \&enwik_parse,
    'default' => \&enwik_parse,
);
our $REDIRECT_LABEL = "redir";
our $TARGET_LANGUAGES = qw(English);

our @TEST_WORDS = ('linking');

our $REDIS = redis_connect();

my @article_filters = ('Wiktionary:', 'Help:', 'Appendix:', 
                       'Main page:', 'Category:', 'Template:', 'Index:');

my (@mediawiki_dumps) = @ARGV;

if (grep {-f $_} @mediawiki_dumps != scalar @mediawiki_dumps 
    || length(@mediawiki_dumps) == 0){
     print STDERR "Usage: $0 <wiktionary XML dumpfile 1> <dumpfile 2> <...>.\n\n";
     print STDERR "Subsequent dumpfile defintions used if not found in previous files\n";
     print STDERR "i.e. dumpfile 2 fills in the gaps not found in dumpfile 2\n";
     exit;
}

for my $mediawiki_dump (@mediawiki_dumps){
    print STDERR "Parsing $mediawiki_dump...\n";
    read_in_xml_dict($mediawiki_dump, \@article_filters);
}

print join(", ", @mediawiki_dumps) ."now imported into Redis.\n\n";

print<<"EOI";
Find words like this:
\$ redis-cli
redis> LRANGE <word> 0 -1
redis> LRANGE table 0 -1
redis> LRANGE "Pacific Ocean" 0 -1

EOI

########## Subs ##########

sub read_in_xml_dict{
    my ($dict_file, $article_filters) = @_;

    my $mw = MediaWiki::DumpFile->new;
    my $pages = $mw->pages($dict_file);
    my $base = $pages->base;
    my $item_count = 0;

    while (defined(my $page = $pages->next)){
        my $text = $page->revision->text;
        my $word = $page->title;
        my %defns;
        my $parser = $PARSERS{$base} || $PARSERS{default};

        # some words are also stored in templates, usually with multi-spellings 
        #$word =~ s/^Template\://;

        #next unless grep { lc($word) eq $_ } @TEST_WORDS;
        #print STDERR $text;

        # don't relate to words
        next if $word =~ /^MediaWiki:/;

        print STDERR "Parsed $word: $item_count\n" if $item_count++ % 1000 == 0 
                                                   && $DEBUG;

        next if grep { $word =~ /$_/ } @$article_filters;

        my @stored_defs = $REDIS->lrange(lc($word), 0, -1);
       
        next if scalar @stored_defs > 0;
       
        %defns = &$parser($text, $page);

        if (keys %defns){
            write_to_redis($word, \%defns);
        }
        else {
            print STDERR "   ** No defns for $word\n" if $DEBUG;
        }
    }

}

sub write_to_redis{
    my ($word, $defns) = @_;

   for my $pos (sort keys %{$defns}){
       for my $defn (@{$defns->{$pos}}){
           print STDERR "  Adding $word:$pos: $defn\n" if $DEBUG;
           my $cmd = $REDIS->rpush(lc($word), "$pos\:\:\:$defn") if $defn;
       }
   }
}

sub redis_connect{
    my $r = Redis->new(server => $REDIS_SERVER_IP);
    $r->ping || die "No server";

    print STDERR "Connected to Redis...\n";
    return $r;
}

############# Parsers ################

sub simplewik_parse{
    my ($text) = @_;

    my $pos;
    my %defns = ();

    foreach my $line (split(/\n/, $text)){
        chomp $line;

        if ($line =~ /(?=^\{?)\=\= ?([\w\s]+) ?\=\=/){
            $pos = lc($1);
            $pos =~ s/^ | $//g;
            $defns{$pos} = ();
        }
        elsif ($pos && $line =~ /^\#([^:].*)/){
            my $def = $1;
            $def =~ s/^ | $//g;
            push @{$defns{$pos}}, $def;
        }
        elsif ($line =~ /\{\{plural of\|(.*?)\}\}/){
            push @{$defns{$pos}}, $line;
        }
        elsif ($line =~ /^\#REDIRECT ?\[\[(.*?)\]\]/i){
            push @{$defns{$REDIRECT_LABEL}}, $1;
        }
    }

    return %defns;
}

sub enwik_parse{
    my ($text) = @_;
    my $pos;
    my $correct_language = 1;
    my %defns = ();
    my $lang;

    # only interested in English words (for now)
    #if ($text =~ /^\=\=(?!English).*\=\=/){
    #    return;
    #}
    #else{
    #    $lang = "English";
    #}

    #return if $text !~ /^== ?English ?==/i;

    foreach my $line (split(/\n/, $text)){
        chomp $line;
            
        # get part of speech ($pos)
        if ($line =~ /^\=\= ?([\w\s]+) ?\=\=/){
            last if $1 ne "English";
        }
        elsif ($line =~ /(?=^\{?)\=\=\=?[ \{\}]*([\w\s]+)[ \{\}]*\=\=\=?/){
        # this format in En Wiktionary: 2 letter language code + PoS
        #if ($line =~ /^\{\{(\w\w)\-([\w\-]+)/){
            $pos = lc($1);
            $pos =~ s/^ | $//g;
            $defns{$pos} = ();
        }
        # new language - don't need
        
        #elsif ($line =~ /^{{(\w+)}}$/){
        #    $pos = $1;
        #}
        # get definitions
        elsif ($pos && $line =~ /^\#([^:*].*)/){
            my $def = $1;
            $def =~ s/^ | $//g;
            push @{$defns{$pos}}, $def;
        }
    }

    return %defns;
}

