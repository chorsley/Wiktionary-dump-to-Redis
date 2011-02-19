use MediaWiki::DumpFile;
use Data::Dumper;
use Redis;
use strict;

our $REDIS_SERVER_IP = "127.0.0.1:6379";
our $DEBUG = 0;

my $target_langauge = "English";
my @test_words = ('actuality', 'set', 'ramparts', 'touch base');
my @article_filters = ('Wiktionary:', 'Template:', 'Help:', 'Appendix:', 
                       'Main page:', 'Category:');

my %words;
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
    %words = read_in_xml_dict($mediawiki_dump, \@article_filters);
}

# check for words that don't import properly
# turn this into a unit test at some stage.
for my $word (@test_words){
    print STDERR "$word: " . Dumper($words{$word}) if $DEBUG;
}

write_to_redis(\%words);

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
    my $item_count = 0;

    while (defined(my $page = $pages->next)){
        my $text = $page->revision->text;
        my $word = $page->title;
        my $pos;
        my $correct_language = 1;

        print STDERR "Parsed $word: $item_count\n" if $item_count++ % 1000 == 0 
                                                   && $DEBUG;

        next if grep { $word =~ /$_/ } @$article_filters;
        # words could be created by previous dump files
        next if exists $words{$word};

        # only interested in English words (for now
        if ($text =~ /^==(?!English).*==/){
            next;
        }

        $words{$word} = {};

        foreach my $line (split(/\n/, $text)){
            chomp $line;
            print STDERR "$line\n" if grep ($_ eq $word, @test_words) 
                                      && $DEBUG;
        
                
            # get part of speech ($pos)
            #if ($line =~ /(?=^\{?)\=\=\=? ?([\w\s]+) ?\=\=\=?/){
            # this format in En Wiktionary: 2 letter language code + PoS
            if ($line =~ /^{{(\w\w)\-([\w\-]+)/){
                if ($1 eq "en"){
                    $pos = lc($2);
                    $pos =~ s/^ | $//g;
                    $words{$word}{$pos} = ();
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
                push @{$words{$word}{$pos}}, $def;
            }
        }
    }

    return %words;
}

sub write_to_redis{
    my ($words) = @_;

    my $r = Redis->new(server => $REDIS_SERVER_IP);
    $r->ping || die "No server";

    print STDERR "Connected to Redis...\n";

    for my $word (keys %$words){
       for my $pos (sort keys %{$words->{$word}}){
           print STDERR "Adding $word:$pos\n" if $DEBUG;
           for my $defn (@{$words->{$word}{$pos}}){
               print STDERR "  Adding def: $defn\n" if $DEBUG;
               my $cmd = $r->rpush(lc($word), "$pos\:\:\:$defn") if $defn;
           }
       }
    }
}
