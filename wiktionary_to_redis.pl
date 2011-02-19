use MediaWiki::DumpFile;
use Data::Dumper;
use Redis;
use strict;

our $REDIS_SERVER_IP = "127.0.0.1:6379";
our $DEBUG = 1;
our %PARSERS = (
    'http://simple.wiktionary.org/wiki/Main_Page' => \&simplewik_parse,
    'http://en.wiktionary.org/wiki/Wiktionary:Main_Page' => \&enwik_parse,
);

our $REDIS = redis_connect();

my $target_langauge = "English";
my @article_filters = ('Wiktionary:', 'Template:', 'Help:', 'Appendix:', 
                       'Main page:', 'Category:');

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

        print STDERR "Parsed $word: $item_count\n" if $item_count++ % 1000 == 0 
                                                   && $DEBUG;

        next if grep { $word =~ /$_/ } @$article_filters;

        my @stored_defs = $REDIS->lrange(lc($word), 0, -1);
        #print Dumper @v . "\n";
        if (scalar @stored_defs == 0){
             print "ADDING $word not in\n";
             print join ", ", @stored_defs;
        }

        next if scalar @stored_defs > 0;
       
        my %defns = $PARSERS{$base}($text, $page);      

        if (keys %defns){
            print STDERR "   Defs: ". Dumper %defns. "\n";
            write_to_redis($word, \%defns);
        }
        else {
            print STDERR "   ** No defns for $word\n";
        }
    }

}

sub write_to_redis{
    my ($word, $defns) = @_;

   for my $pos (sort keys %{$defns}){
       print STDERR "Adding $word:$pos\n" if $DEBUG;
       for my $defn (@{$defns->{$pos}}){
           print STDERR "  Adding def: $defn\n" if $DEBUG;
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
    }

    return %defns;
}

sub enwik_parse{
    my ($text) = @_;

    my $pos;
    my $correct_language = 1;
    my %defns = ();

    # only interested in English words (for now
    if ($text =~ /^==(?!English).*==/){
        next;
    }

    foreach my $line (split(/\n/, $text)){
        chomp $line;
            
        # get part of speech ($pos)
        #if ($line =~ /(?=^\{?)\=\=\=? ?([\w\s]+) ?\=\=\=?/){
        # this format in En Wiktionary: 2 letter language code + PoS
        if ($line =~ /^\{\{(\w\w)\-([\w\-]+)/){
            if ($1 eq "en"){
                $pos = lc($2);
                $pos =~ s/^ | $//g;
                $defns{$pos} = ();
            }
            # another language
            else{
                $pos = undef;
            }
        }
        elsif ($line =~ /^{{(\w+)}}$/){
            $pos = $1;
        }
        # get definitions
        elsif ($pos && $line =~ /^\#([^:].*)/){
            my $def = $1;
            $def =~ s/^ | $//g;
            push @{$defns{$pos}}, $def;
        }
    }

}

