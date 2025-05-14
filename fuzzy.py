import pandas as pd
from rapidfuzz import fuzz

def get_obr_type_code_matched_records(transaction_df, excel_data_sel, name_threshold=85):
    matched_records = []

    # Iterate over each transaction row
    for _, trans_row in transaction_df.iterrows():
        name = trans_row['Obligor_name_matched']
        type_code = trans_row['Obligation Type Code']

        # Function to apply fuzzy matching to all names in excel_data_sel
        def is_fuzzy_match(target_name):
            return fuzz.partial_ratio(str(target_name).lower(), str(name).lower()) >= name_threshold

        # Apply fuzzy matching filter
        name_matches = excel_data_sel[excel_data_sel['NAME'].apply(is_fuzzy_match)]
        
        # Further filter by type_code
        type_code_matches = name_matches[name_matches['Obligation Type Code'] == type_code]

        # If exactly one match, add the transaction row
        if len(type_code_matches) == 1:
            matched_records.append(trans_row)

    return pd.DataFrame(matched_records)
