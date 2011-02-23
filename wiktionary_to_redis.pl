#!/usr/bin/perl -w

use MediaWiki::DumpFile;
use Data::Dumper;
use Redis;
use strict;
$|++;

our $VERSION = 0.2;

################ settings as you like ###############

our $REDIS_SERVER_IP = "127.0.0.1:6379";
our $DEBUG = 0;
our $REDIRECT_LABEL = "redir";
# En Wiktionary contains multi-languages - limit to below
# only tested for English
our $TARGET_LANGUAGE = "English";

################### settings finish ################

our $REDIS = redis_connect();

our %PARSERS = (
    'http://simple.wiktionary.org/wiki/Main_Page' => \&simplewik_parse,
    'http://en.wiktionary.org/wiki/Wiktionary:Main_Page' => \&enwik_parse,
    'default' => \&enwik_parse,
);

my @article_filters = ('Wiktionary:', 'MediaWiki:', 'Help:', 'Appendix:', 
                       'Main page:', 'Category:', 'Template:', 'Index:');

my (@mediawiki_dumps) = @ARGV;

if (grep {-f $_} @mediawiki_dumps != scalar @mediawiki_dumps 
    || length(@mediawiki_dumps) == 0){
     print STDERR "Usage: $0 <wiktionary XML dumpfile 1> <dumpfile 2> ...\n\n";
     print STDERR "Definitions for earlier files used first.\n";
     print STDERR "i.e. dumpfile 2 fills in the gaps not found in dumpfile 1\n";
     exit;
}

for my $mediawiki_dump (@mediawiki_dumps){
    print STDERR "Parsing $mediawiki_dump...\n";
    read_in_xml_dict($mediawiki_dump, \@article_filters);
}

print join(", ", @mediawiki_dumps) ." now imported into Redis.\n\n";

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

        print STDERR "Parsed $word: $item_count\n" if ++$item_count % 1000 == 0;

        # skip non-word articles
        next if grep { $word =~ /$_/ } @$article_filters;

        # check if word already stored, skip if so
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
        elsif ($pos && $line =~ /\{\{plural of\|(.*?)\}\}/){
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
    my $head_depth = 3;

    foreach my $line (split(/\n/, $text)){
        chomp $line;
        # get part of speech ($pos)
        if ($line =~ /^\=\= ?([\w\s]+) ?\=\=/){
            # TODO: this only works for English, as it is always first on page
            last if $1 ne $TARGET_LANGUAGE;
        }
        # if there are multiple etymologies, headings for PoS are one lv deeper
        elsif ($line =~ /^\={$head_depth} ?Etymology 1 ?\={$head_depth}/i){
            $head_depth++;
        }
        # a part of speech header e.g. === Noun ===
        elsif ($line =~ /^\={$head_depth}[ \{\}]*([\w\s]+)[ \{\}]*\={$head_depth}/){
            $pos = lc($1);
            $pos =~ s/^ | $//g;
            $defns{$pos} = () if !exists $defns{$pos};
        }
        # the definition itself
        elsif ($pos && $line =~ /^\#([^:*].*)/){
            my $def = $1;
            $def =~ s/^ | $//g;
            push @{$defns{$pos}}, $def;
        }
    }

    return %defns;
}

