--[[
    2D shadow rendering demo

    Copyright 2019 Justin Stanley

    Permission is hereby granted, free of charge, to any person obtaining a
    copy of this software and associated documentation files (the "Software"),
    to deal in the Software without restriction, including without limitation
    the rights to use, copy, modify, merge, publish, distribute, sublicense,
    and/or sell copies of the Software, and to permit persons to whom the
    Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in
    all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
    FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
    IN THE SOFTWARE.
--]]

-- 'screen_lightmap' stores the light information for the entire screen before
-- it is composited over the world.
local screen_lightmap = nil

-- 'screen_lightmap_blur' is an intermediate texture used during blurring
local screen_lightmap_blur = nil

-- 'world_canvas' stores an intermediate framebuffer for the world BEFORE
-- any lighting is applied.
local world_canvas = nil

-- 'light_texture' is used to render each light. it can be modified to change
-- the light's "shape".
local light_texture = love.graphics.newImage('light.png')
local spotlight_texture = love.graphics.newImage('spotlight.png')

-- 'floor_texture' is rendered as the world backdrop
local floor_texture = love.graphics.newImage('floor.png')

-- 'lights' stores the information for each light
-- each light is of the form { x, y, color, radius, angle, image }
-- lights[1] will be moved by the mouse cursor.
-- lights[2] will be rotated at 60RPM
local lights = {
    {
        x = 0,
        y = 0,
        color = {0.5, 0.5, 0.5, 1},
        radius = 400,
        angle = 0,
        image = light_texture
    }, 
    {
        x = 550,
        y = 300,
        color = {0.7, 0, 0.2, 1},
        radius = 500,
        angle = 0,
        image = spotlight_texture
    }, 
    {
        x = 50,
        y = 50,
        color = {0.1, 0, 0.3, 1},
        radius = 1000,
        angle = 0,
        image = light_texture
    },
}

-- 'shader_compose' stores a pixel shader used to combine 'screen_lightmap' and
-- 'world_canvas' into the final rendering result
local shader_compose = love.graphics.newShader([[
    uniform Image world_tex;
    uniform Image lightmap_tex;

    vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords) {
        /* perform a light blend. a black light pixel should result in a black
           output, and a white light pixel results in doubled brightness */

        vec4 world_texel = Texel(world_tex, texture_coords);
        vec4 light_texel = Texel(lightmap_tex, texture_coords);

        light_texel.a = world_texel.a = 1.0;

        return light_texel * vec4(2.0) * world_texel;
    }
]])

local shader_hblur = love.graphics.newShader([[
    uniform vec2 tc_pixel_dist;

    vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords) {
        const float kernel[7] = float[7](
            0.00598, 0.06062, 0.24184, 0.38310,
            0.24184, 0.06062, 0.00598
        );

        vec4 out_color = vec4(0.0);

        for (int i = -3; i <= 3; ++i) {
            out_color += vec4(kernel[i + 3]) * Texel(tex, texture_coords + vec2(tc_pixel_dist.x, 0.0) * i);
        }

        out_color.a = 1.0;
        return out_color;
    }
]])

local shader_vblur = love.graphics.newShader([[
    uniform vec2 tc_pixel_dist;

    vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords) {
        const float kernel[7] = float[7](
            0.00598, 0.06062, 0.24184, 0.38310,
            0.24184, 0.06062, 0.00598
        );

        vec4 out_color = vec4(0.0);

        for (int i = -3; i <= 3; ++i) {
            out_color += vec4(kernel[i + 3]) * Texel(tex, texture_coords + vec2(0.0, tc_pixel_dist.x) * i);
        }

        out_color.a = 1.0;
        return out_color;
    }
]])

-- world_blocks defines the solid walls in the demo.
-- each block is of the form { x, y, w, h, r }
local world_blocks = {
    { x = 300, y = 300, w = 100, h = 100 },
    { x = 100, y = 400, w = 50, h = 200 },
    { x = 500, y = 400, w = 100, h = 10 },
    { x = 300, y = 100, w = 130, h = 100 },
}

function love.load()
    print('Starting shadow demo.')

    local sw, sh = love.graphics.getDimensions()

    --[[
        first, we need to generate a list of line segments representing the
        outline of the world. this will be very important in computing the
        geometry of the shadows.

        we also compute the normal vector for each segment. this will be useful
        in culling out front-facing segments (which we do NOT want to cast
        shadows from)
    --]]

    for _, v in ipairs(world_blocks) do
        -- compute the segments in a clockwise manner

        v.segments = {
            {
              a = { x = v.x, y = v.y },
              b = { x = v.x + v.w, y = v.y },
              normal = { x = 0, y = -1 },
            },
            {
              a = { x = v.x + v.w, y = v.y },
              b = { x = v.x + v.w, y = v.y + v.h },
              normal = { x = 1, y = 0 },
            },
            {
              a = { x = v.x + v.w, y = v.y + v.h },
              b = { x = v.x, y = v.y + v.h },
              normal = { x = 0, y = 1 },
            },
            {
              a = { x = v.x, y = v.y + v.h },
              b = { x = v.x, y = v.y },
              normal = { x = -1, y = 0 },
            },
        }
    end

    --[[
        next, we need to do some preparation for each light; we need a render
        target for each light to store the pixels it's illuminating (lightmap)
    --]]

    for _, v in ipairs(lights) do
        v.lightmap = love.graphics.newCanvas(v.radius * 2, v.radius * 2)
    end

    --[[
        finally, initialize the screen lightmap and world canvas
    --]]

    screen_lightmap = love.graphics.newCanvas(sw, sh)
    screen_lightmap_blur = love.graphics.newCanvas(sw, sh)
    world_canvas = love.graphics.newCanvas(sw, sh)
end

function love.resize(w, h)
    -- regenerate render targets that depend on the window size
    screen_lightmap = love.graphics.newCanvas(w, h)
    screen_lightmap_blur = love.graphics.newCanvas(w, h)
    world_canvas = love.graphics.newCanvas(w, h)
end

function love.update(dt)
    -- here we'll update the light location from the cursor.
    lights[1].x, lights[1].y = love.mouse.getPosition()
    lights[2].angle = lights[2].angle + dt * 3.141
end

function love.draw()
    --[[
        the render pipeline is as follows:
            (1) each light's 'lightmap' is filled with the 'light_texture' data
            (2) for each light, render black shadows over their lightmap in the
                appropriate locations.
            (3) the screen lightmap is cleared to black
            (4) each light's lightmap is additively drawn to 'screen_lightmap'
                in the appropriate locations.
            (5) the world is drawn using 'screen_lightmap' to determine each
                pixels' illumination
    --]]

    local sw, sh = love.graphics.getDimensions()

    --[[
        (1) clear each light's RT to 'light_texture'
    --]]

    for _, v in ipairs(lights) do
        local lt_w, lt_h = v.image:getDimensions()

        love.graphics.setCanvas(v.lightmap)
        love.graphics.clear()
        love.graphics.setColor(v.color)
        love.graphics.push()
        love.graphics.translate(v.radius, v.radius)
        love.graphics.rotate(v.angle)
        love.graphics.translate(-v.radius, -v.radius)
        love.graphics.draw(v.image, 0, 0, 0, 
                           v.radius * 2 / lt_w,
                           v.radius * 2 / lt_h)
        love.graphics.pop()
    end

    --[[
        (2) render shadow onto lightmaps
    --]]

    for _, light in ipairs(lights) do
        love.graphics.setCanvas(light.lightmap)
        love.graphics.setColor(0, 0, 0, 1)

        -- we want to draw a quadrilateral from each back-facing edge
        -- so, start iterating world line segments and testing the normals

        for _, block in ipairs(world_blocks) do
            for _, segment in ipairs(block.segments) do
                -- is the segment normal facing away from the light?
                if segment_back_facing(light, segment) then
                    -- yes. render a shadow from this segment!
                    -- to compute the quadrilateral coordinates, we project
                    -- the segment vertices way out into space and then fill
                    -- the whole area with black.
                    
                    -- projecting each vertex by the light radius is an easy
                    -- way to guarantee that it will cover the whole lightmap
                    -- (unless the light and segment are < 0.5 pixels apart)
                    
                    local vert_a = {
                        x = (segment.a.x - light.x),
                        y = (segment.a.y - light.y),
                    }

                    local vert_b = {
                        x = (segment.b.x - light.x),
                        y = (segment.b.y - light.y),
                    }
                
                    local vert_c = {
                        x = vert_a.x * light.radius,
                        y = vert_a.y * light.radius,
                    }

                    local vert_d = {
                        x = vert_b.x * light.radius,
                        y = vert_b.y * light.radius,
                    }

                    --[[ 
                        with all 4 of the shadow vertices, we are ready to
                        render to the lightmap
                    
                        the quadrilateral function expects vertices in clockwise
                        order. fortunately, we defined the world segments in a
                        clockwise manner so we can guarantee the order will be
                        correct.

                        before we render, we need to center the viewport on the
                        light, so the lightmap is rendered correctly.
                    --]]
                  
                    love.graphics.push()
                    love.graphics.translate(light.radius, light.radius)

                    love.graphics.setColor(0, 0, 0, 1)
                    love.graphics.polygon('fill',
                                          vert_c.x, vert_c.y, 
                                          vert_d.x, vert_d.y,
                                          vert_b.x, vert_b.y,
                                          vert_a.x, vert_a.y)

                    love.graphics.pop()
                end
            end
        end
    end

    --[[
        (3, 4) render each individual lightmap onto the screen lightmap
    --]]
    
    love.graphics.setCanvas(screen_lightmap)
    love.graphics.clear()
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setBlendMode('add')

    for _, light in ipairs(lights) do
        love.graphics.draw(light.lightmap, light.x - light.radius, light.y - light.radius)
    end

    -- blur the screen lightmap onto itself to smooth lights
    love.graphics.setShader(shader_hblur)
    love.graphics.setCanvas(screen_lightmap_blur)
    love.graphics.clear()

    shader_hblur:send('tc_pixel_dist', { 1 / sw, 1 / sh })
    
    love.graphics.draw(screen_lightmap, 0, 0)

    love.graphics.setShader(shader_vblur)
    love.graphics.setCanvas(screen_lightmap)
    love.graphics.clear()

    shader_vblur:send('tc_pixel_dist', { 1 / sw, 1 / sh })
    
    love.graphics.draw(screen_lightmap_blur, 0, 0)
    love.graphics.setShader()

    -- render the world to the world canvas

    love.graphics.setCanvas(world_canvas)
    love.graphics.setBlendMode('alpha')
    love.graphics.clear(0.6, 0.6, 0.6, 1)

    -- draw the floor backdrop
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(floor_texture, 0, 0, 0,
                       sw / floor_texture:getWidth(),
                       sh / floor_texture:getHeight())

    -- draw the world blocks
    love.graphics.setColor(0.8, 0.8, 0.8, 0.8)

    for _, block in ipairs(world_blocks) do
        love.graphics.rectangle('fill', block.x, block.y, block.w, block.h)
    end

    -- subtract a constant vec4 from the screen lightmap where it intersects the world
    -- reduces light brightness on top of world blocks, making diffusion more realistic
    -- wrote with rendering the world again, might be able to be improved (but probably not)
    local dc = 0.45
    love.graphics.setCanvas(screen_lightmap)
    love.graphics.setColor({ 1, 1, 1, dc });
    love.graphics.setBlendMode('subtract')

    for _, block in ipairs(world_blocks) do
        love.graphics.rectangle('fill', block.x, block.y, block.w, block.h)
    end

    -- send the world canvas and the lightmap to the final compositing shader
    love.graphics.setCanvas()
    love.graphics.clear()
    love.graphics.setShader(shader_compose)

    shader_compose:send('world_tex', world_canvas)
    shader_compose:send('lightmap_tex', screen_lightmap)

    love.graphics.setBlendMode('add')
    love.graphics.draw(screen_lightmap, 0, 0)

    love.graphics.setShader()

    -- reset everything
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setBlendMode('alpha')
end

function segment_back_facing(light, segment)
    -- to determine whether a line segment is facing towards a light, we
    -- perform a vector dot product between the segment normal and the vector
    -- from the segment's midpoint to the light. the result will be negative
    -- if and only if the normal is backfacing.
    
    local midpoint = {
        x = (segment.a.x + segment.b.x) / 2,
        y = (segment.a.y + segment.b.y) / 2,
    }

    local a = segment.normal

    local b = {
        x = light.x - midpoint.x,
        y = light.y - midpoint.y,
    }

    return (a.x * b.x + a.y * b.y < 0)
end
