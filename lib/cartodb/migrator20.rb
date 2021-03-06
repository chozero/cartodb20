class Migrator20

  def migrate!
    @logger = Logger.new(STDOUT)
    @tables_skipped     = 0
    @tables_migrated    = 0
    @tables_with_errors = {}

    Table.select(:id, :database_name, :name, :user_id).all.each do |table|
      if already_migrated?(table)
        log "* Skipping: #{table.name}"
        @tables_skipped += 1
      else
        begin
          log "* Migrating: #{table.name}"

          log "  - Adding table_id"
          add_table_id(table)

          log "  - Creating default map and layers"
          table.create_default_map_and_layers if table.map.blank?
          table.reload

          log "  - Migrating map"
          migrate_table_map(table)

          log "  - Migrating layers"
          migrate_table_layers(table)
          migrated!(table)
        rescue => e
          log "!! Exception on #{table.name}\n#{e.inspect}"
          username = table.owner.username rescue ""
          @tables_with_errors[username] ||= []
          @tables_with_errors[username] << [table.name, e.inspect]
        end      
      end
    end

    log("\n=================================")
    log("Done!")
    log("- Tables migrated:       #{@tables_migrated}")
    log("- Tables skipped:        #{@tables_skipped}")
    log("- Tables with errors:")
    log("#{y(@tables_with_errors)}")
  end

  def add_table_id(table)
    if table.table_id.blank?
      table.this.update(:table_id => table.owner.in_database.select(:pg_class__oid)
        .from(:pg_class)
        .join_table(:inner, :pg_namespace, :oid => :relnamespace)
        .where(:relkind => 'r', :nspname => 'public', :relname => table.name)
        .first[:oid])
    end
  end

  def migrate_table_map(table)
    map_metadata = JSON.parse($tables_metadata.hget(table.key, 'map_metadata')) rescue {}
    map = table.map

    # All previous maps were based on google maps
    map.provider = "googlemaps"

    # Copy center from redis, set map bounds if not set there
    if map_metadata["latitude"].blank? || map_metadata["longitude"].blank?
      bounds = map.get_map_bounds

      long = (bounds[:minx] + bounds[:maxx]) / 2
      lat  = (bounds[:miny] + bounds[:maxy]) / 2
      map.center =  "[#{lat}, #{long}]"

      map.view_bounds_sw = nil
      map.view_bounds_ne = nil
    else
      map.center = "[#{map_metadata["latitude"]},#{map_metadata["longitude"]}]"
    end

    map.zoom = (map_metadata["zoom"].blank? ? 2 : map_metadata["zoom"])
    map.save
  end

  def migrate_table_layers(table)
    map_metadata = JSON.parse($tables_metadata.hget(table.key, 'map_metadata')) rescue {}
    infowindow_metadata = JSON.parse($tables_metadata.hget(table.key, 'infowindow')) rescue {}

    
    # Data layer setup
    data_layer = table.map.data_layers.first    

    data_layer.options               = data_layer.options.except('style_version')
    data_layer.options['kind']       = 'carto'
    data_layer.options["table_name"] = table.name
    data_layer.options["user_name"]  = table.owner.username
    data_layer.options['tile_style'] = JSON.parse(
      $tables_metadata.get("map_style|#{table.database_name}|#{table.name}")
    )['style'] rescue nil

    # Fix for bubblemaps
    # We have to apply an SQL to bubble maps until Mapnik 2.1.1 is released
    if data_layer.options['tile_style'].present? && 
       table.the_geom_type == "multipolygon" &&
       data_layer.options['tile_style'] =~ /.*marker-placement:\s*point.*/
      fields = table.schema(:reload => true).map {|i| i.first.to_s } - ["the_geom_webmercator"]
      data_layer.options['query'] = "SELECT #{fields.join(',')}, ST_PointOnSurface(the_geom_webmercator) as the_geom_webmercator FROM #{table.name}"
    end

    # First, try to read infowindow fields from Redis
    infowindow_fields = infowindow_metadata.select { |k,v| 
      v.to_s == "true" && !['created_at', 'updated_at', 'the_geom'].include?(k) 
    }.map {|k,v| k }
    
    # Fill with default infowindow fields if we got nothing before
    if infowindow_fields.blank?
      infowindow_fields = table.schema(reload: true).map { |field| 
        if !["the_geom", "updated_at", "created_at"].include?(field.first.to_s.downcase) && !(field[1].to_s =~ /^geo/)
          field.first.to_s
        end
      }.compact 
    end

    # Remove all fields only when all fields have been marked as not included
    infowindow_fields = [] if (infowindow_metadata.present? && infowindow_metadata.all? { |k,v| v == false })

    data_layer.infowindow = {
      "fields"         => infowindow_fields
                            .each_with_index
                            .map { |column_name, i| { name: column_name, title: true, position: i+1 } },
      "template_name"  => "table/views/infowindow_light"
    }
    data_layer.save


    # Base layer setup
    base_layer = table.map.base_layers.first

    base_layer.kind = 'gmapsbase'

    # Former satellite maps are now hybrid (satellite maps now don't show any labels)
    map_metadata["google_maps_base_type"] = 'hybrid' if map_metadata["google_maps_base_type"] == 'satellite'
    base_layer.options = {
      'style'     => map_metadata["google_maps_customization_style"],
      'base_type' => (map_metadata["google_maps_base_type"].blank? ? 'roadmap' : map_metadata["google_maps_base_type"])
    }
    base_layer.save
  end

  def already_migrated?(table)
    $tables_metadata.hget(table.key, 'migrated_to_20').to_s == "true"
  end

  def migrated!(table)
    @tables_migrated += 1
    $tables_metadata.hset(table.key, 'migrated_to_20', true)
  end

  def log msg
    @logger.debug(msg)
  end

end
