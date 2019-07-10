# A DSpace wrapper around escholarship, used to integrate eschol content into Symplectic Elements

require 'date'
require 'pp'
require 'time'

###################################################################################################
def serveUnitRSS(unitID)

  # Generate a GraphQL query that gives all the data needed for the feed
  query = """
    unit(id: $unitID) {
      name
      items(order:ADDED_DESC, first:100) {
        nodes {
          id
          title
          abstract
          permalink
          added
        }
      }
    }
  """
  data = apiQuery(query, { unitID: ["ID!", unitID] })

  # Create a little XML chunk for each item
  itemChunks = []
  items = data.dig("unit", "items", "nodes") or halt(404, "Unit not found.\n")
  items.each { |item|
    descrip = item['abstract'] && !item['abstract'].strip.empty? ? item['abstract'] : item['title']
    descrip.size > 1000 and descrip = descrip[0..((descrip.index(' ',990) || 1000)-1)] + "..."
    date = DateTime.parse(item['added']).rfc2822
    itemChunks << xmlGen('''
      <item>
        <title><%= item["title"] %></title>
        <link><%= item["permalink"] %></link>
        <description><%= descrip %></description>
        <guid isPermaLink="true"><%= item["permalink"] %></guid>
        <pubDate><%= date %></pubDate>
      </item>''', binding, xml_header: false)
  }

  # And generate the outer wrapper
  content_type "text/xml"
  unitName = data.dig("unit", "name")
  xmlGen('''
    <rss xmlns:atom="http://www.w3.org/2005/Atom" version="2.0">
      <channel>
        <docs>http://www.rssboard.org/rss-specification</docs>
        <atom:link rel="self" type="application/rss+xml" href="https://escholarship.org/uc/<%=unitID%>/rss"/>
        <ttl>720</ttl>
        <title>Recent <%= unitID %> items</title>
        <link>https://escholarship.org/uc/<%= unitID %>/rss</link>
        <description>Recent eScholarship items from <%= unitName %></description>
        <pubDate><%= DateTime.now.rfc2822 %></pubDate>
        <%== itemChunks.join("\n") %>
      </channel>
    </rss>''', binding)
end