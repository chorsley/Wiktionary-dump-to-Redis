use MediaWiki::DumpFile;
use Data::Dumper;
use Redis;
use strict;

our $DEBUG = 0;
my %words;
my $mediawiki_dump = $ARGV[0];

if (!-f $mediawiki_dump){
     print STDERR "Usage: $0 <wiktionary XML dumpfile>.\n";
     print STDERR "Ensure redis-server is running beforehand.\n";
     exit;
}

my @test_words = qw'actuality set';
my @article_filters = ('Wiktionary:', 'Template:', 'Help:', 'Appendix:', 
                       'Main page:', 'Category:');

my %words = read_in_xml_dict($mediawiki_dump, \@article_filters);

for my $word (@test_words){
    print STDERR "$word: " . Dumper($words{$word}) if $DEBUG;
}

write_to_redis(\%words);

print<<"EOI";
$mediawiki_dump has been imported into Redis.

Find words like this:
\$ redis-cli
redis> LRANGE <word> 0 -1
redis> LRANGE table 0 -1

Spaces in words and parts of speech replaced by underscore (_).
EOI

########## Subs ##########

sub read_in_xml_dict{
    my ($dict_file, $article_filters) = @_;

    my $mw = MediaWiki::DumpFile->new;
    my $pages = $mw->pages($dict_file);

    while (defined(my $page = $pages->next)){
        my $text = $page->revision->text;
        my $word = $page->title;
        my $pos;

        next if grep { $word =~ /$_/ } @$article_filters;

        $words{$word} = {};

        foreach my $line (split(/\n/, $text)){
            chomp $line;
            print STDERR "$line\n" if grep ($_ eq $word, @test_words) 
                                      && $DEBUG;
            
            if ($line =~ /(?=^\{?)\=\= ?([\w\s]+) ?\=\=/){
                $pos = lc($1);
                # trim
                $pos =~ s/^ | $//g;
                $words{$word}{$pos} = ();
            }
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

    my $r;
    # assume Redis on localhost, standard port
    eval{
        $r = Redis->new;
    };
    die "Couldn't connect to Redis: $@" if $@;

    for my $word (keys %$words){
       for my $pos (sort keys %{$words->{$word}}){
           print STDERR "Adding $word:$pos\n" if $DEBUG;
           for my $defn (@{$words->{$word}{$pos}}){
               # TODO: Can Redis handle spaces in key names?
               $word =~ s/ /_/g;
               $pos =~ s/ /_/g;
               $r->rpush("$word", "$pos\:\:\:$defn") if $defn;
           }
       }
    }
}
