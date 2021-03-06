class BrowserTest < ActiveRecord::Base
  before_save :split_agent
  def split_agent
    BrowserTest.split_agent_for self
  end
  
  # Multi line graph of batch size vs. baselined timing z-scores 
  def self.graph_batch_size
    # iPhone has WAY higher times. Exclude or the graph gets skewed.
    x = ActiveRecord::Base.connection.execute 'select c, avg(bogus) as bog, timing, batch_size, method, browser from browser_tests as b inner join (
      select count(*) as c, round(avg(timing)) as timing, batch_size, method, browser from method_timings where os != "iPhone/iPod" and with_variants = 1 
      group by browser, method, batch_size having c > 10) as t
      using (browser, method) group by browser, method, batch_size having bog < 1 order by browser, method, batch_size;'
    results = []
    x.each_hash{|y| results << y.to_options!} # put it in something that won't disappear after being used, and can be mapped etc
    # make it look nice
    results.map{|x| [:batch_size, :timing, :c].each{|y| x[y] = x[y].to_i}; x[:bog] = x[:bog].to_f; x }
    # e.g.:
    # {:batch_size=>100, :timing=>1064, :method=>"full_reinsert", :bog=>0.0185, :browser=>"Firefox", :c=>25}
    
    # cf. http://code.google.com/apis/chart/
    google_url = "http://chart.apis.google.com/chart?cht=lxy&chs=750x400"
    
    grouped_results = results.group_by{|x| "#{x[:method]} / #{x[:browser]}"}.sort_by{|k,v| v[0][:method] + ' / ' + v[0][:browser]}.map{|k,v| [k, v.sort_by{|y| y[:batch_size] }] }
    
    # calculate z-scores
    # S.D. = sqrt( mean of squares - square of mean )
    # z-score = (x - mean) / s.d.
    
    means = grouped_results.map{|k,a| a.map{|x| x[:timing] }.mean }
    sds = grouped_results.map{|k,a| Math.sqrt(a.map{|x| x[:timing] ** 2}.mean - (a.map{|x| x[:timing]}.mean ** 2)) }
    grouped_results.each_with_index{|g,i| g[1].map{|r| r[:zscore] = (sds[i] == 0 ? 0 : (r[:timing] - means[i]) / sds[i] ) } } # if sd = 0, call the zscore 0 to prevent NaNs
    
    # Scaling.
    xmax = results.map{|x|x[:batch_size]}.max 
    ymax = results.map{|x|x[:zscore]}.max
    ymin = results.map{|x|x[:zscore]}.min
    # google_url += "&chds=0,#{xmax},0,#{ymax}"
    
    # Simple-encoded data, scaled to 0-61
    google_url += "&chd=s:" + grouped_results.map{|k,v| 
      v.map{|x| senc((61.999*x[:batch_size]/xmax).to_i)}.join + ',' + 
      v.map{|x| senc((61.999*(x[:zscore]-ymin)/(ymax-ymin)).to_i)}.join # no delimiters within one dataset except between xdata & ydata
    }.join(',')
    
    sd_markers = (-10..10).select{|x| x > ymin and x < ymax}
    sd_locations = sd_markers.map{|x| (100.999*(x-ymin)/(ymax-ymin)).to_i }
    sd_range = [-1,0,1].map{|x| sd_locations[sd_markers.index(x)] / 100.0}
    
    # Axis labels
    google_url += "&chxt=x,x,y,y&chxr=0,0,#{xmax}" + 
                  "&chm=h,777777,0,#{ sd_range[1] },1|r,DDDDDD,0,#{ sd_range[0] },#{ sd_range[2] }" +
                  "&chxp=1,50|2,#{sd_locations.join(',')}|3,50" +
                  "&chxl=1:|batch size|2:|#{sd_markers.map{|x| x.to_s + ' σ'}.join('|') }|3:|z-score" # chxr |2,#{ymin},#{ymax},1
    
    # Legend
    # google_url += "&chdl=" + grouped_results.map{|k,v| k}.join('|')
    
    # colors
    google_url += "&chco=" + grouped_results.map{|k,v| self.color_for(v[0][:method], v[0][:browser])[1..-1] }.join(',')
    
    return google_url
  end
  
  # Bar chart of URLs/min by method & browser
  def self.graph_method_timings
    x = ActiveRecord::Base.connection.execute "select c, avg(bogus) as bog, timing, method, browser from browser_tests as b inner join (
      select count(*) as c, round(avg(timing)) as timing, method, browser from method_timings where os != 'iPhone/iPod' and with_variants = 1
      group by browser, method having c > 10) as t
      using (browser, method) group by browser, method having bog < 1 order by browser, method;"
    results = []
    x.each_hash{|y| results << y.to_options!} # put it in something that won't disappear after being used, and can be mapped etc
    # make it look nice
    results.map{|x| [:timing, :c].each{|y| x[y] = x[y].to_i}; x[:bog] = x[:bog].to_f; x[:urls] = (60000 / x[:timing]).to_i; x }
    # e.g. {:timing=>492, :bog=>0.0, :method=>"jquery", :browser=>"Explorer", :c=>8}
    
    # grouped vertical bar graph
    google_url = "http://chart.apis.google.com/chart?cht=bvg&chs=750x400"
    
    # Scaling.
    ymax = results.map{|x|x[:urls]}.max
    # google_url += "&chds=0,#{ymax}"
    google_url += "&chbh=a" # automatically scale bar widths
    
    # we have to ensure every cross product is present even if there isn't the data for it
    methods = results.map{|x|x[:method]}.sort.uniq
    browsers = results.map{|x|x[:browser]}.sort.uniq
    methods.each do |m|
      browsers.each do |b|
        if results.select{|x| x[:method] == m and x[:browser] == b}.empty?
          results << {:browser => b, :method => m} # :urls nil by default
        end
      end
    end
    
    # things *next* to each other are in *different* groups
    grouped_results = results.group_by{|x| x[:browser] }.sort_by{|k,v| v[0][:browser]}.map{|k,v| [k, v.sort_by{|y| y[:method]}] }
    
    # Simple-encoded data, scaled to 0-61
    google_url += "&chd=s:" + grouped_results.map{|k,v| 
      v.map{|x| senc(x[:urls] ? (61.999*x[:urls]/ymax).to_i : nil)}.join 
    }.join(',')
    
    # Axis labels
    google_url += "&chxt=x,y,y&chxr=1,0,#{ymax}" + 
                  "&chxp=2,50" +
                  "&chxl=2:|kURLs/min|0:|#{methods.join('|')}"
    
    # Legend
#    google_url += "&chdl=" + grouped_results.map{|k,v| k}.join('|')
    
    # annotations of browsers, tied to their best result
    bests = browsers.map do |b|
      r = results.sort_by{|x| x[:browser] + ' / ' + x[:method]}.select{|x|x[:browser]==b }.map{|x|x[:urls]||0}
      r.index r.max
    end
    
    i = -1
    google_url += "&chm=" + browsers.map{|b| i+=1; "A#{b},000000,#{i},#{ bests[i] },16" }.join('|') 
    # + "|v,999999,#{ browsers.count },,1,0,sl:15:10" # vertical ticks between bar groups 
    
    # colors
    google_url += "&chco=" + grouped_results.map{|k,v| v.map{|y| self.color_for(y[:method], y[:browser])[1..-1]}.join('|') }.join(',')
    
    return google_url
    
  end
  
  def self.used_agents
    self.find(:first, :select => "group_concat(distinct browser) as browsers").browsers.split(',').sort
  end
  
  def self.used_methods
    BrowserTest.find(:first, :select => "group_concat(distinct method) as xmethods", :conditions => 'bogus = 0').xmethods.split(',').sort
  end
  
  def self.hues
    i = 0
    used_methods.inject({}){|m, method| m[method] = (0 + (i * 1.0 / used_methods.count)) % 1.0; i += 1; m } # 0 = base hue
  end
  
  def self.luminosities
    i = 0
    used_agents.inject({}){|m, method| m[method] = (i * 0.5 / (used_agents.count - 1)) + 0.25; i += 1; m }
  end
  
  def self.color_for method, agent
    Color::HSL.from_fraction(self.hues[method], 1, self.luminosities[agent]).html
  end
  
  
  # simple encoding - 3x more compact for values 0..61
  # http://code.google.com/apis/chart/formats.html#simple
  def self.senc i
    case i
    when 0..25: ('A'[0] + i).chr
    when 26..51: ('a'[0] + i - 26).chr
    when 52..61: ('0'[0] + i - 52).chr
    when nil: '_'
    end
  end
  
  def self.split_agent_for foo
    foo.browser = browser(foo.user_agent)
    foo.browser = nil if foo.browser == 'Unknown'
    foo.os = os(foo.user_agent)
    foo.os = nil if foo.os == 'Unknown'
    foo.version = version(foo.user_agent)
    foo.version = nil if foo.version == 'Unknown'
    foo
  end
  
  def self.browser user_agent
    case user_agent
      when /Chrome/: 'Chrome'
      when /OmniWeb/: 'OmniWeb'
      when /Apple/: 'Safari'
      when /Opera/: 'Opera' # shouldn't actually work, but just in case
      when /iCab/: 'iCab'
      when /KDE/: 'Konqueror'
      when /Firefox/: 'Firefox'
      when /Camino/: 'Camino'
      when /Netscape/: 'Netscape'
      when /MSIE/: 'Explorer'
      when /Gecko/: 'Mozilla'
      when /Mozilla/: 'Netscape'
      else 'Unknown'
    end
  end
  
  def self.os user_agent
    case user_agent
      when /iPhone/: 'iPhone/iPod'
      when /Mac/: 'Mac'
      when /Linux/: 'Linux'
      when /Win/: 'Windows'
      else 'Unknown'
    end
  end
  
  
  def self.version user_agent
    case user_agent
      when /Chrome/: user_agent[/Chrome\w*.([\d.]+)/,1]
      when /OmniWeb/: user_agent[/OmniWeb\w*.([\d.]+)/,1]
      when /Apple/: user_agent[/Version\w*.([\d.]+)/,1]
      when /Opera/: user_agent[/Opera\w*.([\d.]+)/,1]
      when /iCab/: user_agent[/iCab\w*.([\d.]+)/,1]
      when /KDE/: user_agent[/KDE\w*.([\d.]+)/,1]
      when /Firefox/: user_agent[/Firefox\w*.([\d.]+)/,1]
      when /Camino/: user_agent[/Camino\w*.([\d.]+)/,1]
      when /Netscape/: user_agent[/Netscape\w*.([\d.]+)/,1]
      when /MSIE/: user_agent[/MSIE\w*.([\d.]+)/,1]
      when /Gecko/: user_agent[/rv\w*.([\d.]+)/,1]
      when /Mozilla/: user_agent[/Mozilla\w*.([\d.]+)/,1]
      else 'Unknown'
    end
  end
end
