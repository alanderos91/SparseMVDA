function process_splice(local_path, dataset)
    # Encode data in a binary format.
    # This expand 60 variables (nucleotides at ordered sites) to 120 variables. 
    classes, sample_ids, sequences = String[], String[], BitVector[]
    for line in eachline(local_path)
        # Read information for current sample.
        c, id, s = map(strip, split(line, ','))

        # Skip samples with ambiguous sequences.
        if occursin(r"[DNSR]", s)
            continue
        end

        # Encode string sequence of nucleotides to binary format.
        bit_sequence = BitVector(undef, 4*length(s))
        for (i, nucleotide) in enumerate(s)
            if nucleotide == 'T'
                w, x, y, z = false, false, false, true # T ==> [0, 0, 0, 1]
            elseif nucleotide == 'G'
                w, x, y, z = false, false, true, false # G ==> [0, 0, 1, 0]
            elseif nucleotide == 'C'
                w, x, y, z = false, true, false, false # C ==> [0, 1, 0, 0]
            else # nucleotide == 'A'
                w, x, y, z = true, false, false, false # A ==> [1, 0, 0, 0]
            end
            bit_sequence[4*i-3] = w
            bit_sequence[4*i-2] = x
            bit_sequence[4*i-1] = y
            bit_sequence[4*i] = z
        end

        push!(classes, c)
        push!(sample_ids, id)
        push!(sequences, bit_sequence)
    end

    function label_mapping(old_label)
        if old_label == "EI"
            return "exon-intron"
        elseif old_label == "IE"
            return "intron-exon"
        else # old_label == N
            return "neither"
        end
    end

    dir = dirname(local_path)
    tmpfile = joinpath(dir, "$(dataset).tmp")
    mat = vcat(sequences'...)
    df = hcat(DataFrame(class=classes), DataFrame(mat, :auto))
    CSV.write(tmpfile, df, header=false)

    # Standardize format.
    MVDA.process_dataset(tmpfile, dataset;
        label_mapping=label_mapping,
        header=false,
        class_index=1,
        variable_indices=2:ncol(df),
        ext=".csv",
    )

    # Store row and column information.
    info_file = joinpath(dir, "$(dataset).info")
    col_info = [["junction"]; ["site$(i)_$(j)" for i in 1:60 for j in ('A','C','G')]]
    col_info_df = DataFrame(cols=col_info)
    CSV.write(info_file, col_info_df; writeheader=false, delim=',', append=false)

    info_file = joinpath(dir, "$(dataset).id")
    row_info = sample_ids
    row_info_df = DataFrame(rows=row_info)
    CSV.write(info_file, row_info_df; writeheader=false, delim=',', append=true)

    return nothing
end

push!(
    MESSAGES[],
    """
    ## Dataset: splice

    **3 classes / 3176 instances (14 dropped) / 240 variables**

    See: https://archive.ics.uci.edu/ml/datasets/Molecular+Biology+(Splice-junction+Gene+Sequences)

    The original sequences of 60 nucleotides are expanded to 240 variables using the binary encoding

        T ==> [0,0,0,1]
        G ==> [0,0,1,0]
        C ==> [0,1,0,0]
        A ==> [1,0,0,0]

    14 instances with ambiguous sequences are dropped. Although representable with 3 bits, the 4 bit
    version allows us to determine whether a site is important; e.g. does [0,0,0] mean T or not
    important in the 3 bit version? 
    """
)

push!(REMOTE_PATHS[], "https://archive.ics.uci.edu/ml/machine-learning-databases/molecular-biology/splice-junction-gene-sequences/splice.data")

push!(CHECKSUMS[], "ebbae10c85d3c285e2a2489a37e42bc2ee8d91d15005e391a9962fa3389a114f")

push!(FETCH_METHODS[], DataDeps.fetch_default)

push!(POST_FETCH_METHODS[], path -> process_splice(path, "splice"))

push!(DATASETS[], "splice")
