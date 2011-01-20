use MediaWiki::DumpFile;
use Data::Dumper;
use AnyEvent::Redis;
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

print STDERR "Parsing $mediawiki_dump...\n";
%words = read_in_xml_dict($mediawiki_dump, \@article_filters);

# check for words that don't import properly
# turn this into a unit test at some stage.
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
           
            # get part of speech ($pos)
            if ($line =~ /(?=^\{?)\=\= ?([\w\s]+) ?\=\=/){
                $pos = lc($1);
                $pos =~ s/^ | $//g;
                $words{$word}{$pos} = ();
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

    my $r = AnyEvent::Redis->new(
        host     => '127.0.0.1',
        encoding => 'utf8',
        on_error => sub { die @_ },
    );
    print STDERR "Connecting to Redis...\n";
    my $info = $r->info->recv;
    print STDERR "Adding words to Redis...\n";

    for my $word (keys %$words){
       for my $pos (sort keys %{$words->{$word}}){
           print STDERR "Adding $word:$pos\n" if $DEBUG;
           for my $defn (@{$words->{$word}{$pos}}){
               print STDERR "  Adding def: $defn\n" if $DEBUG;
               my $cmd = $r->rpush($word, "$pos\:\:\:$defn") if $defn;
           }
       }
    }
}
